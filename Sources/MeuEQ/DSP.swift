import Accelerate
import Foundation
import os

/// Uma banda do equalizador: frequência central em Hz e ganho em dB.
struct Band: Codable, Equatable {
    var freq: Double
    var gain: Double

    static let q = 1.41  // largura fixa, mais ou menos uma oitava
    static let defaults: [Band] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        .map { Band(freq: $0, gain: 0) }
}

/// Coeficientes de um filtro biquad, já divididos por a0.
struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    /// Filtro "peaking" do Audio EQ Cookbook (Robert Bristow-Johnson).
    static func peaking(_ band: Band, sampleRate: Double) -> Biquad {
        let f = min(band.freq, sampleRate * 0.45)  // acima de Nyquist o filtro fica instável
        let a = pow(10, band.gain / 40)
        let w0 = 2 * Double.pi * f / sampleRate
        let alpha = sin(w0) / (2 * Band.q)
        let cosw = cos(w0)
        let a0 = 1 + alpha / a
        return Biquad(b0: (1 + alpha * a) / a0, b1: -2 * cosw / a0, b2: (1 - alpha * a) / a0,
                      a1: -2 * cosw / a0, a2: (1 - alpha / a) / a0)
    }

    /// Quanto este filtro muda o volume (em dB) na frequência `freq`. É o que desenha a curva.
    func responseDB(at freq: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * freq / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
    }
}

/// Equalizador que roda dentro do callback de áudio: lá dentro não aloca memória nem espera lock.
/// A interface grava os ajustes em `pending`; o áudio copia para `active` quando consegue o lock.
final class EQProcessor {
    static let maxBands = 10
    private let active = UnsafeMutablePointer<Biquad>.allocate(capacity: maxBands)
    private let pending = UnsafeMutablePointer<Biquad>.allocate(capacity: maxBands)
    private let state = UnsafeMutablePointer<Double>.allocate(capacity: maxBands * 2 * 2)  // banda × canal × (z1, z2)
    private var activeCount = 0, pendingCount = 0
    private var activeGain: Float = 1, pendingGain: Float = 1
    private var activeBypass = true, pendingBypass = true
    private var hasPending = false
    private let lock = OSAllocatedUnfairLock()

    init() { reset() }

    /// Zera a memória dos filtros. Só chamar com o áudio parado.
    func reset() { state.update(repeating: 0, count: Self.maxBands * 4) }

    /// Chamado pela interface sempre que algo muda.
    func update(bands: [Band], preampDB: Double, bypass: Bool, sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        pendingCount = min(bands.count, Self.maxBands)
        for i in 0..<pendingCount { pending[i] = .peaking(bands[i], sampleRate: sampleRate) }
        pendingGain = Float(pow(10, preampDB / 20))
        pendingBypass = bypass
        hasPending = true
    }

    /// Processa os canais esquerdo e direito no próprio buffer.
    // ponytail: troca de coeficiente sem rampa; se arrastar a banda fizer "zíper" audível, interpolar os coeficientes.
    func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int) {
        if lock.lockIfAvailable() {
            if hasPending {
                active.update(from: pending, count: pendingCount)
                activeCount = pendingCount
                activeGain = pendingGain
                activeBypass = pendingBypass
                hasPending = false
            }
            lock.unlock()
        }
        if activeBypass { return }

        for ch in 0..<2 {
            let buf = ch == 0 ? left : right  // sem array aqui: criar array aloca memória no callback
            for b in 0..<activeCount {
                let c = active[b]
                let s = state + (b * 2 + ch) * 2
                var z1 = s[0], z2 = s[1]
                for i in 0..<frames {  // forma direta transposta II
                    let x = Double(buf[i])
                    let y = c.b0 * x + z1
                    z1 = c.b1 * x - c.a1 * y + z2
                    z2 = c.b2 * x - c.a2 * y
                    buf[i] = Float(y)
                }
                s[0] = z1
                s[1] = z2
            }
            // ponytail: corte seco em ±1 para não estourar; trocar por limitador se o ganho alto distorcer.
            for i in 0..<frames { buf[i] = max(-1, min(1, buf[i] * activeGain)) }
        }
    }
}

/// Guarda os últimos samples (mono) para o analisador de espectro.
final class SampleRing {
    static let size = 8192
    private let buf = UnsafeMutablePointer<Float>.allocate(capacity: size)
    private var write = 0
    private let lock = OSAllocatedUnfairLock()

    init() { buf.update(repeating: 0, count: Self.size) }

    /// Lado do áudio: se a interface estiver lendo, pula este bloco (é só visual).
    func push(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, frames: Int) {
        guard lock.lockIfAvailable() else { return }
        for i in 0..<frames {
            buf[write] = (left[i] + right[i]) * 0.5
            write = (write + 1) & (Self.size - 1)
        }
        lock.unlock()
    }

    /// Lado da interface: copia em ordem, do mais antigo para o mais novo.
    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return (0..<Self.size).map { buf[(write + $0) & (Self.size - 1)] }
    }
}

/// Transforma os samples em níveis por faixa de frequência, como o RTA de uma mesa digital.
final class Analyzer {
    static let points = 240              // pontos desenhados de 20 Hz a 20 kHz
    static let minFreq = 20.0, maxFreq = 20000.0
    static let n = SampleRing.size
    private let log2n = vDSP_Length(log2(Double(n)))
    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: n)
    private let windowSum: Float
    private var ranges: [(lo: Int, hi: Int, nearest: Int, widthBins: Float)] = []
    private var rangesRate = 0.0

    static func freq(ofPoint i: Int) -> Double {
        minFreq * pow(maxFreq / minFreq, Double(i) / Double(points - 1))
    }

    init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(Self.n), Int32(vDSP_HANN_DENORM))
        windowSum = window.reduce(0, +)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Cada ponto mede uma faixa de 1/6 de oitava em volta dele (as faixas se sobrepõem, o desenho fica liso).
    private func prepareRanges(sampleRate: Double) {
        let binHz = sampleRate / Double(Self.n)
        let half = pow(2, 1.0 / 12)
        ranges = (0..<Self.points).map { i in
            let f = Self.freq(ofPoint: i)
            let lo = f / half, hi = f * half
            return (Int((lo / binHz).rounded(.up)), Int((hi / binHz).rounded(.down)),
                    max(1, Int((f / binHz).rounded())), Float((hi - lo) / binHz))
        }
        rangesRate = sampleRate
    }

    /// Nível de cada ponto em dB (uma senoide de volume máximo dá 0 dB).
    func levelsDB(_ samples: [Float], sampleRate: Double) -> [Float] {
        if sampleRate != rangesRate { prepareRanges(sampleRate: sampleRate) }
        let half = Self.n / 2
        var windowed = [Float](repeating: 0, count: Self.n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(Self.n))

        var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes {
                    vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }
        // |saída|² / soma(janela)² = amplitude²; /2 vira potência RMS; /1,5 desconta a largura da janela Hann.
        let scale = 1 / (windowSum * windowSum * 2 * 1.5)
        let maxBin = half - 1
        return ranges.map { r in
            let lo = min(r.lo, maxBin), hi = min(r.hi, maxBin)
            var mean: Float
            if hi >= lo {
                mean = 0
                for k in lo...hi { mean += power[k] }
                mean /= Float(hi - lo + 1)
            } else {
                mean = power[min(r.nearest, maxBin)]
            }
            let bandPower = mean * scale * r.widthBins
            return 10 * log10(bandPower * 2 + 1e-12)  // ×2: referência é a senoide de pico 1
        }
    }
}
