import CoreAudio
import Foundation

struct EngineError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw EngineError("\(what) falhou (código \(status))") }
}

/// Captura o som de todos os apps (Process Tap), passa pelo EQ e toca na saída padrão.
///
/// Caminho: tap global que exclui o próprio MeuEQ e silencia o som original enquanto é lido
/// → aggregate device privado (saída padrão + tap) → IOProc: lê o tap, equaliza, escreve na saída.
/// Se o app fechar ou travar, o macOS desfaz o tap e o som volta ao normal sozinho.
final class AudioEngine {
    let eq = EQProcessor()
    let ring = SampleRing()
    private(set) var sampleRate = 48000.0
    private(set) var deviceName = ""

    private let system = AudioHardwareSystem.shared
    private var tap: AudioHardwareTap?
    private var aggregate: AudioHardwareAggregateDevice?
    private var procID: AudioDeviceIOProcID?
    private var tapInterleaved = true

    private static let maxFrames = 16384
    private let left = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let right = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)

    func start() throws {
        stop()
        do { try startUnchecked() } catch { stop(); throw error }
    }

    private func startUnchecked() throws {
        guard let me = try system.process(for: getpid()) else {
            throw EngineError("O macOS não registrou o MeuEQ como app de áudio")
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [me.id])
        description.uuid = UUID()
        description.name = "MeuEQ"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        guard let tap = try system.makeProcessTap(description: description) else {
            throw EngineError("Não consegui criar a captura do áudio do sistema")
        }
        self.tap = tap

        guard let output = try system.defaultOutputDevice else {
            throw EngineError("Nenhuma saída de som selecionada")
        }
        let outputUID = try output.uid
        deviceName = try output.name

        guard let aggregate = try system.makeAggregateDevice(description: [
            kAudioAggregateDeviceNameKey: "MeuEQ",
            kAudioAggregateDeviceUIDKey: "com.tulio.meueq.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: try tap.uid,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]) else {
            throw EngineError("Não consegui montar o dispositivo de áudio do MeuEQ")
        }
        self.aggregate = aggregate

        let tapFormat = try tap.format
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0, tapFormat.mBitsPerChannel == 32 else {
            throw EngineError("Formato de áudio inesperado na captura")
        }
        tapInterleaved = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        sampleRate = try aggregate.nominalSampleRate
        eq.reset()

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate.id, nil) { [unowned self] _, input, _, output, _ in
            self.render(input, output)
        }, "Criar o processamento de áudio")

        // Fones Bluetooth têm microfone na mesma "caixa". Se o microfone ligar, o fone cai para
        // qualidade de ligação. Por isso só a entrada do tap fica ativa.
        let deviceInputs = try output.streams.filter { try $0.direction == .input }.count
        if deviceInputs > 0 { try useOnlyLastInputs(skipping: deviceInputs) }

        let inputs = try aggregate.streams.filter { try $0.direction == .input }.count
        FileHandle.standardError.write(Data("""
            MeuEQ: saída=\(deviceName) taxa=\(sampleRate) tap=\(tapFormat.mChannelsPerFrame)ch \
            \(tapInterleaved ? "intercalado" : "separado") entradas=\(inputs) (\(deviceInputs) do aparelho)\n
            """.utf8))

        try aggregate.start(IOProcID: procID)
    }

    /// Desliga as primeiras `skip` entradas do aggregate (as do aparelho) para este IOProc.
    private func useOnlyLastInputs(skipping skip: Int) throws {
        guard let aggregate, let procID else { return }
        let total = try aggregate.streams.filter { try $0.direction == .input }.count
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let countOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mNumberStreams)!
        let size = flagsOffset + 4 * total
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        raw.storeBytes(of: procID, as: AudioDeviceIOProcID.self)
        raw.storeBytes(of: UInt32(total), toByteOffset: countOffset, as: UInt32.self)
        for i in 0..<total {
            raw.storeBytes(of: UInt32(i < skip ? 0 : 1), toByteOffset: flagsOffset + 4 * i, as: UInt32.self)
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectSetPropertyData(aggregate.id, &address, 0, nil, UInt32(size), raw),
                  "Desligar o microfone do aparelho")
    }

    func stop() {
        if let aggregate {
            if let procID {
                try? aggregate.stop(IOProcID: procID)
                AudioDeviceDestroyIOProcID(aggregate.id, procID)
            }
            try? system.destroyAggregateDevice(aggregate)
        }
        if let tap { try? system.destroyProcessTap(tap) }
        aggregate = nil
        tap = nil
        procID = nil
    }

    /// Roda na thread de áudio do macOS: nada de alocar, imprimir ou esperar aqui.
    private func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for b in outs where b.mData != nil { memset(b.mData, 0, Int(b.mDataByteSize)) }

        // O tap vem depois das entradas do aparelho: são sempre os últimos buffers.
        var frames = 0
        if tapInterleaved {
            guard let b = ins.last, let p = b.mData?.assumingMemoryBound(to: Float.self) else { return }
            let ch = Int(b.mNumberChannels)
            guard ch > 0 else { return }
            frames = min(Int(b.mDataByteSize) / (4 * ch), Self.maxFrames)
            let r = ch > 1 ? 1 : 0
            for i in 0..<frames {
                left[i] = p[i * ch]
                right[i] = p[i * ch + r]
            }
        } else {
            guard ins.count >= 2,
                  let pl = ins[ins.count - 2].mData?.assumingMemoryBound(to: Float.self),
                  let pr = ins[ins.count - 1].mData?.assumingMemoryBound(to: Float.self) else { return }
            frames = min(Int(ins[ins.count - 1].mDataByteSize) / 4, Self.maxFrames)
            left.update(from: pl, count: frames)
            right.update(from: pr, count: frames)
        }

        eq.process(left, right, frames: frames)
        ring.push(left, right, frames: frames)

        guard let first = outs.first, let op = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        let ch = Int(first.mNumberChannels)
        if ch >= 2 {
            for i in 0..<min(frames, Int(first.mDataByteSize) / (4 * ch)) {
                op[i * ch] = left[i]
                op[i * ch + 1] = right[i]
            }
        } else if outs.count >= 2, let op2 = outs[1].mData?.assumingMemoryBound(to: Float.self) {
            let n = min(frames, Int(first.mDataByteSize) / 4, Int(outs[1].mDataByteSize) / 4)
            op.update(from: left, count: n)
            op2.update(from: right, count: n)
        } else if ch == 1 {
            for i in 0..<min(frames, Int(first.mDataByteSize) / 4) { op[i] = (left[i] + right[i]) * 0.5 }
        }
    }
}
