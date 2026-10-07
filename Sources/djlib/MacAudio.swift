import Accelerate
import AVFoundation
import Combine

// This Mac's audio: AVAudioEngine playing one file at a time through a 10-band EQ, with a spectrum tap for the
// visualiser (only installed while a visualiser is on screen). Core Audio reads every format in the crate —
// FLAC, ALAC/AAC, MP3, WAV/AIFF, Opus, OGG, Dolby E-AC-3 (mixed down to stereo by the engine) — so nothing has
// to be converted.

@MainActor
final class MacAudio {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: EQ.frequencies.count)
    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0   // where the scheduled segment starts
    private var pausedAt: Double = 0
    private var token = 0                               // invalidates completion handlers after a seek / load
    var onEnd: (() -> Void)?

    init() {
        engine.attach(node)
        engine.attach(eq)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)
        EQ.shared.apply(to: eq)
        // Headphones plugged in, output device changed: the engine stops; pick up where it was.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recover() }
        }
    }

    var hasFile: Bool { file != nil }
    var isPlaying: Bool { node.isPlaying && engine.isRunning }
    var duration: Double { file.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0 }
    var volume: Double {
        get { Double(engine.mainMixerNode.outputVolume) }
        set { engine.mainMixerNode.outputVolume = Float(max(0, min(1, newValue))) }
    }

    var position: Double {
        guard let f = file else { return 0 }
        guard node.isPlaying, let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt) else { return pausedAt }
        return min(duration, Double(startFrame + pt.sampleTime) / f.processingFormat.sampleRate)
    }

    func load(_ path: String) throws {
        let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        token += 1
        node.stop()
        // Reconnect for this file's format (sample rate / channels); the mixer converts to the output.
        // The EQ runs at the file's own format (it can't convert); the mixer after it converts to the output.
        let wasRunning = engine.isRunning
        if wasRunning { engine.pause() }
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(eq)
        engine.connect(node, to: eq, format: f.processingFormat)
        engine.connect(eq, to: engine.mainMixerNode, format: f.processingFormat)
        if wasRunning { try? engine.start() }
        file = f
        pausedAt = 0
        schedule(from: 0)
    }

    func play() {
        guard file != nil else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { print("audio engine: \(error)") }
        }
        node.play()
    }

    func pause() {
        pausedAt = position
        node.pause()
    }

    func seek(_ seconds: Double) {
        guard let f = file else { return }
        let wasPlaying = isPlaying
        let frame = AVAudioFramePosition(max(0, min(seconds, duration)) * f.processingFormat.sampleRate)
        pausedAt = Double(frame) / f.processingFormat.sampleRate
        schedule(from: frame)
        if wasPlaying { play() }
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let f = file else { return }
        token += 1
        let t = token
        node.stop()
        startFrame = frame
        let count = AVAudioFrameCount(max(0, f.length - frame))
        guard count > 0 else { return }
        node.scheduleSegment(f, startingFrame: frame, frameCount: count, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.token == t { self?.onEnd?() } } }
        }
    }

    private func recover() {
        guard file != nil else { return }
        let at = position, was = node.isPlaying
        try? engine.start()
        seek(at)
        if was { play() }
    }

    /// `djlib play-test <file> [eq preset]`: plays 4 s, seeks to 60 s, prints position and spectrum (dev check).
    static func selfTest(_ args: [String]) async {
        guard let path = args.first else { return print("usage: djlib play-test <file> [preset]") }
        let a = MacAudio()
        if args.count > 1 { EQ.shared.choose(args[1]) }
        do { try a.load(path) } catch { return print("load failed: \(error)") }
        print(String(format: "duration %.1f s", a.duration))
        a.volume = 0.25
        a.spectrum(true)
        a.play()
        try? await Task.sleep(for: .seconds(2))
        print(String(format: "playing=%@ position %.2f", a.isPlaying ? "yes" : "no", a.position))
        print("spectrum", Spectrum.shared.levels.map { String(format: "%.1f", $0) }.joined(separator: " "))
        a.seek(60)
        try? await Task.sleep(for: .seconds(2))
        print(String(format: "after seek position %.2f", a.position))
        a.pause()
        print(String(format: "paused at %.2f", a.position))
        a.spectrum(false)
    }

    // MARK: spectrum for the visualiser

    private var tapping = false
    private var spectrumUsers = 0
    /// Each visualiser on screen asks for the spectrum (on) and lets go (off); the tap runs while anyone needs it.
    func spectrum(_ on: Bool) {
        spectrumUsers = max(0, spectrumUsers + (on ? 1 : -1))
        let want = spectrumUsers > 0
        guard want != tapping else { return }
        tapping = want
        let mixer = engine.mainMixerNode
        if want {
            let analyser = Spectrum.shared
            mixer.installTap(onBus: 0, bufferSize: 2048, format: mixer.outputFormat(forBus: 0)) { buffer, _ in
                analyser.feed(buffer)
            }
        } else {
            mixer.removeTap(onBus: 0)
            Spectrum.shared.reset()
        }
    }
}

// MARK: - EQ

/// 10-band graphic EQ (±12 dB) shared by the full player, the mini player and the now-playing bar.
@MainActor
final class EQ: ObservableObject {
    static let shared = EQ()
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]
    static let presets: [(String, [Float])] = [
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass boost", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("Club", [4, 3, 2, 0, -1, -1, 0, 2, 3, 3]),
        ("Hip-hop", [5, 4, 1, 2, -1, -1, 1, 0, 2, 3]),
        ("Electronic", [4, 3, 1, 0, -2, 1, 0, 1, 3, 4]),
        ("Vocal", [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
        ("Treble", [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        ("Loudness", [5, 3, 0, 0, -1, 0, -1, 0, 3, 4]),
    ]

    @Published var gains: [Float] { didSet { save() } }
    @Published var on: Bool { didSet { save() } }
    @Published var preset: String { didSet { UserDefaults.standard.set(preset, forKey: "eqPreset") } }
    private weak var unit: AVAudioUnitEQ?

    private init() {
        let saved = UserDefaults.standard.array(forKey: "eqGains") as? [Float]
        gains = saved?.count == Self.frequencies.count ? saved! : Array(repeating: 0, count: Self.frequencies.count)
        on = UserDefaults.standard.object(forKey: "eqOn") as? Bool ?? true
        preset = UserDefaults.standard.string(forKey: "eqPreset") ?? "Flat"
    }

    func apply(to eq: AVAudioUnitEQ) {
        unit = eq
        eq.globalGain = 0
        for (i, b) in eq.bands.enumerated() {
            b.filterType = i == 0 ? .lowShelf : i == eq.bands.count - 1 ? .highShelf : .parametric
            b.frequency = Self.frequencies[i]
            b.bandwidth = 1.0
            b.bypass = false
        }
        update()
    }

    func set(_ band: Int, _ gain: Float) {
        gains[band] = max(-12, min(12, gain))
        preset = "Custom"
    }

    func choose(_ name: String) {
        guard let p = Self.presets.first(where: { $0.0 == name }) else { return }
        gains = p.1
        preset = name
    }

    private func save() {
        UserDefaults.standard.set(gains, forKey: "eqGains")
        UserDefaults.standard.set(on, forKey: "eqOn")
        update()
    }

    private func update() {
        guard let eq = unit else { return }
        eq.bypass = !on
        for (i, b) in eq.bands.enumerated() { b.gain = gains[i] }
    }
}

// MARK: - Spectrum

/// 32 log-spaced bands, 0…1, smoothed (fast attack, slow fall) — what the visualisers draw.
final class Spectrum: ObservableObject, @unchecked Sendable {
    static let shared = Spectrum()
    static let bands = 32
    @Published private(set) var levels = [Float](repeating: 0, count: Spectrum.bands)

    private let n = 2048
    private lazy var fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(n))), radix: .radix2, ofType: DSPSplitComplex.self)
    private lazy var window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
    private var smooth = [Float](repeating: 0, count: Spectrum.bands)
    private var last = Date.distantPast
    private let lock = NSLock()

    func reset() {
        lock.lock(); smooth = .init(repeating: 0, count: Self.bands); lock.unlock()
        DispatchQueue.main.async { self.levels = .init(repeating: 0, count: Self.bands) }
    }

    /// From the audio thread.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0, let fft else { return }
        // Mono mix of the first two channels (zero-padded to the FFT size), windowed.
        var mono = [Float](repeating: 0, count: n)
        let chans = Int(buffer.format.channelCount), len = min(Int(buffer.frameLength), n)
        for c in 0..<min(chans, 2) {
            for i in 0..<len { mono[i] += ch[c][i] }
        }
        mono = vDSP.multiply(mono, window)
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                mono.withUnsafeBufferPointer { mp in
                    mp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                }
                fft.forward(input: split, output: &split)
                vDSP.absolute(split, result: &mags)
            }
        }
        // Log-spaced bands from ~40 Hz to ~16 kHz, in dB, mapped to 0…1.
        let sr = Float(buffer.format.sampleRate), binHz = sr / Float(n)
        var out = [Float](repeating: 0, count: Self.bands)
        for b in 0..<Self.bands {
            let lo = 40 * pow(400, Float(b) / Float(Self.bands)), hi = 40 * pow(400, Float(b + 1) / Float(Self.bands))
            let i0 = max(1, Int(lo / binHz)), i1 = max(i0 + 1, min(n / 2, Int(hi / binHz)))
            let peak = mags[i0..<i1].max() ?? 0
            let db = 20 * log10(max(peak / Float(n), 1e-7))
            out[b] = max(0, min(1, (db + 70) / 60))
        }
        lock.lock()
        for b in 0..<Self.bands { smooth[b] = out[b] > smooth[b] ? out[b] : smooth[b] * 0.82 + out[b] * 0.18 }
        let snapshot = smooth
        lock.unlock()
        // ~30 updates a second is plenty for the eye and keeps the UI cheap.
        let now = Date()
        guard now.timeIntervalSince(last) > 0.03 else { return }
        last = now
        DispatchQueue.main.async { self.levels = snapshot }
    }
}
