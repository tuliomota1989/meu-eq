import AppKit
import CoreAudio
import SwiftUI

@main
struct MeuEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = EQModel()

    init() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
            exit(0)
        }
    }

    var body: some Scene {
        Window("MeuEQ", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 880, height: 540)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Estado da tela. Cada mudança vai para o EQ na hora e fica salva para a próxima vez.
final class EQModel: ObservableObject {
    @Published var bands: [Band] { didSet { apply() } }
    @Published var preampDB: Double { didSet { apply() } }
    @Published var enabled: Bool { didSet { apply() } }
    @Published var status = "Iniciando…"
    @Published var dragging: Int?  // banda sendo arrastada (-1 = arrasto fora das bolinhas)

    let engine = AudioEngine()
    private let analyzer = Analyzer()
    private var smoothed = [Float](repeating: -120, count: Analyzer.points)
    private var started = false

    init() {
        let saved = UserDefaults.standard
        bands = saved.data(forKey: "bands").flatMap { try? JSONDecoder().decode([Band].self, from: $0) } ?? Band.defaults
        preampDB = saved.object(forKey: "preampDB") as? Double ?? 0
        enabled = saved.object(forKey: "enabled") as? Bool ?? true
    }

    func start() {
        guard !started else { return }
        started = true
        restart()
        // Trocou de fone ou caixa: refaz tudo na saída nova.
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            self?.restart()
        }
    }

    private func restart() {
        do {
            try engine.start()
            status = "Tocando em: \(engine.deviceName)"
        } catch {
            status = error.localizedDescription
        }
        apply()
    }

    private func apply() {
        engine.eq.update(bands: bands, preampDB: preampDB, bypass: !enabled, sampleRate: engine.sampleRate)
        let saved = UserDefaults.standard
        saved.set(try? JSONEncoder().encode(bands), forKey: "bands")
        saved.set(preampDB, forKey: "preampDB")
        saved.set(enabled, forKey: "enabled")
    }

    /// Espectro suavizado: sobe rápido e desce devagar, como o RTA de mesa.
    func spectrum() -> [Float] {
        let levels = analyzer.levelsDB(engine.ring.snapshot(), sampleRate: engine.sampleRate)
        for i in levels.indices {
            let new = levels[i], old = smoothed[i]
            smoothed[i] = new > old ? old + (new - old) * 0.6 : max(new, old - 0.8)
        }
        return smoothed
    }
}

/// Converte frequência e dB em posição na tela e vice-versa.
struct Graph {
    static let maxDB = 15.0             // a curva vai de -15 a +15 dB
    static let spectrumFloor: Float = -80  // ponytail: faixa fixa do espectro; virar ajuste se a música ficar baixa ou alta demais na tela
    static let minLog = log10(Analyzer.minFreq), maxLog = log10(Analyzer.maxFreq)
    let plot: CGRect

    init(size: CGSize) {
        plot = CGRect(x: 40, y: 10, width: max(1, size.width - 52), height: max(1, size.height - 34))
    }

    func x(_ freq: Double) -> CGFloat { plot.minX + plot.width * (log10(freq) - Self.minLog) / (Self.maxLog - Self.minLog) }
    func freq(_ x: CGFloat) -> Double { pow(10, Self.minLog + (x - plot.minX) / plot.width * (Self.maxLog - Self.minLog)) }
    func y(_ db: Double) -> CGFloat { plot.midY - plot.height / 2 * db / Self.maxDB }
    func db(_ y: CGFloat) -> Double { (plot.midY - y) / (plot.height / 2) * Self.maxDB }
    func ySpectrum(_ db: Float) -> CGFloat {
        plot.maxY - plot.height * CGFloat(max(0, min(1, (db - Self.spectrumFloor) / -Self.spectrumFloor)))
    }
}

struct ContentView: View {
    @ObservedObject var model: EQModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                    Canvas { ctx, size in draw(ctx, Graph(size: size)) }
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(Graph(size: geo.size)))
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                    if let i = nearestBand(to: tap.location, Graph(size: geo.size)) { model.bands[i].gain = 0 }
                })
            }
            .background(Color(white: 0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 14) {
                Toggle("Ligado", isOn: $model.enabled).toggleStyle(.switch)
                Text("Ganho")
                Slider(value: $model.preampDB, in: -12...12).frame(width: 240)
                Text(String(format: "%+.1f dB", model.preampDB)).monospacedDigit().frame(width: 64, alignment: .leading)
                Spacer()
                Button("Zerar EQ") {
                    model.bands = Band.defaults
                    model.preampDB = 0
                }
            }
            Text("\(model.status)  ·  Arraste as bolinhas; clique duplo zera a banda.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 380)
        .onAppear { model.start() }
    }

    private func nearestBand(to point: CGPoint, _ g: Graph) -> Int? {
        let distances = model.bands.map { hypot(g.x($0.freq) - point.x, g.y($0.gain) - point.y) }
        guard let best = distances.indices.min(by: { distances[$0] < distances[$1] }), distances[best] < 24 else { return nil }
        return best
    }

    private func dragGesture(_ g: Graph) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { drag in
                if model.dragging == nil { model.dragging = nearestBand(to: drag.startLocation, g) ?? -1 }
                guard let i = model.dragging, i >= 0 else { return }
                model.bands[i].freq = min(Analyzer.maxFreq, max(Analyzer.minFreq, g.freq(drag.location.x)))
                model.bands[i].gain = min(Graph.maxDB, max(-Graph.maxDB, g.db(drag.location.y)))
            }
            .onEnded { _ in model.dragging = nil }
    }

    private func draw(_ ctx: GraphicsContext, _ g: Graph) {
        let p = g.plot
        let grid = Color.white.opacity(0.12), label = Color.white.opacity(0.5)

        for f in [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000] {
            let x = g.x(f)
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: p.minY)); $0.addLine(to: CGPoint(x: x, y: p.maxY)) }, with: .color(grid))
            let text = f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
            ctx.draw(Text(text).font(.caption2).foregroundColor(label), at: CGPoint(x: x, y: p.maxY + 12))
        }
        for db in stride(from: -12, through: 12, by: 6) {
            let y = g.y(Double(db))
            ctx.stroke(Path { $0.move(to: CGPoint(x: p.minX, y: y)); $0.addLine(to: CGPoint(x: p.maxX, y: y)) },
                       with: .color(db == 0 ? grid.opacity(2.5) : grid))
            ctx.draw(Text(db > 0 ? "+\(db)" : "\(db)").font(.caption2).foregroundColor(label),
                     at: CGPoint(x: p.minX - 16, y: y))
        }

        var plotCtx = ctx
        plotCtx.clip(to: Path(p))

        // Espectro ao vivo (atrás de tudo).
        let levels = model.spectrum()
        var spectrum = Path()
        spectrum.move(to: CGPoint(x: p.minX, y: p.maxY))
        for i in levels.indices {
            spectrum.addLine(to: CGPoint(x: g.x(Analyzer.freq(ofPoint: i)), y: g.ySpectrum(levels[i])))
        }
        spectrum.addLine(to: CGPoint(x: p.maxX, y: p.maxY))
        spectrum.closeSubpath()
        plotCtx.fill(spectrum, with: .linearGradient(
            Gradient(colors: [Color.cyan.opacity(0.6), Color.cyan.opacity(0.08)]),
            startPoint: CGPoint(x: 0, y: p.minY), endPoint: CGPoint(x: 0, y: p.maxY)))

        // Curva do EQ: soma de todas as bandas.
        let fs = model.engine.sampleRate
        let filters = model.bands.map { Biquad.peaking($0, sampleRate: fs) }
        var curve = Path()
        let steps = 300
        for s in 0...steps {
            let f = Analyzer.minFreq * pow(Analyzer.maxFreq / Analyzer.minFreq, Double(s) / Double(steps))
            let point = CGPoint(x: g.x(f), y: g.y(filters.reduce(0) { $0 + $1.responseDB(at: f, sampleRate: fs) }))
            s == 0 ? curve.move(to: point) : curve.addLine(to: point)
        }
        var area = curve
        area.addLine(to: CGPoint(x: p.maxX, y: g.y(0)))
        area.addLine(to: CGPoint(x: p.minX, y: g.y(0)))
        area.closeSubpath()
        let curveColor = model.enabled ? Color.yellow : Color.gray
        plotCtx.fill(area, with: .color(curveColor.opacity(0.15)))
        plotCtx.stroke(curve, with: .color(curveColor), lineWidth: 2.5)

        // Bolinhas das bandas.
        for (i, band) in model.bands.enumerated() {
            let c = CGPoint(x: g.x(band.freq), y: g.y(band.gain))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)),
                     with: .color(i == model.dragging ? .white : .orange))
            ctx.draw(Text("\(i + 1)").font(.system(size: 9, weight: .bold)).foregroundColor(.black), at: c)
        }
        if let i = model.dragging, i >= 0 {
            let band = model.bands[i]
            let freq = band.freq >= 1000 ? String(format: "%.1f kHz", band.freq / 1000) : String(format: "%.0f Hz", band.freq)
            ctx.draw(Text("\(freq)  \(String(format: "%+.1f dB", band.gain))").font(.callout.bold()).foregroundColor(.white),
                     at: CGPoint(x: g.x(band.freq), y: g.y(band.gain) - 22))
        }
    }
}

/// Conferência rápida da matemática: `MeuEQ --selftest`.
enum SelfTest {
    static func run() {
        let fs = 48000.0

        // A curva dá o ganho exato no centro da banda e zero longe dela.
        let peak = Biquad.peaking(Band(freq: 1000, gain: 6), sampleRate: fs)
        precondition(abs(peak.responseDB(at: 1000, sampleRate: fs) - 6) < 0.01, "curva no centro")
        precondition(abs(peak.responseDB(at: 20, sampleRate: fs)) < 0.1, "curva longe da banda")

        // O som de verdade: senoide de 1 kHz com +6 dB sai quase 2x maior.
        let n = 48000
        let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let eq = EQProcessor()
        eq.update(bands: [Band(freq: 1000, gain: 6)], preampDB: 0, bypass: false, sampleRate: fs)
        for i in 0..<n { l[i] = Float(0.25 * sin(2 * .pi * 1000 * Double(i) / fs)); r[i] = l[i] }
        eq.process(l, r, frames: n)
        let out = (n / 2..<n).map { abs(l[$0]) }.max()!
        precondition(abs(out - 0.25 * 1.995) < 0.01, "EQ no áudio: \(out)")

        // Ganho alto não passa de 1 (não estoura).
        eq.update(bands: [], preampDB: 12, bypass: false, sampleRate: fs)
        l[0] = 0.9; r[0] = 0.9
        eq.process(l, r, frames: 1)
        precondition(l[0] == 1, "corte em 1")

        // Analisador: senoide de amplitude 0,5 mede cerca de -6 dB.
        let f = 100 * fs / Double(Analyzer.n)
        let samples = (0..<Analyzer.n).map { Float(0.5 * sin(2 * .pi * f * Double($0) / fs)) }
        let levels = Analyzer().levelsDB(samples, sampleRate: fs)
        let i = (0..<Analyzer.points).min { abs(Analyzer.freq(ofPoint: $0) - f) < abs(Analyzer.freq(ofPoint: $1) - f) }!
        precondition(abs(levels[i] + 6) < 1, "analisador: \(levels[i]) dB")
        precondition(levels[Analyzer.points - 1] < -60, "analisador longe da senoide: \(levels[Analyzer.points - 1]) dB")

        print("selftest ok")
    }
}
