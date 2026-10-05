import Accelerate
import Foundation

// Full-track analysis of local files: BPM (body of the track, not the intro) and musical key in
// Camelot notation. Results are cached by path + modification date + size so files are analysed once.

struct FileAnalysis: Codable {
    var path: String
    var modified: Date?
    var sizeBytes: Int64
    var artist: String?
    var title: String?
    var durationSec: Double?
    var bpm: Double?
    var bpmAmbiguous: Bool
    var bpmAlternate: Double?
    var key: String?            // e.g. "A minor"
    var camelot: String?        // e.g. "8A"
    var keyConfidence: Double?  // 0…1 gap between best and runner-up key
    var libraryTrackID: String?
    var analyzedAt: Date
}

enum Analyzer {
    static let cacheFile = libraryRoot.appendingPathComponent("_cache/analysis.json")

    static func loadCache() -> [String: FileAnalysis] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([String: FileAnalysis].self, from: Data(contentsOf: cacheFile))) ?? [:]
    }

    static func saveCache(_ c: [String: FileAnalysis]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(c).write(to: cacheFile, options: .atomic)
    }

    static func isFresh(_ a: FileAnalysis?, _ rec: TrackRecord) -> Bool {
        guard let a else { return false }
        return a.sizeBytes == rec.sizeBytes && a.modified == rec.modified
    }

    /// Heavy DSP; call off the main thread.
    static func analyze(_ rec: TrackRecord, libraryTrackID: String?) -> FileAnalysis {
        let url = URL(fileURLWithPath: rec.path)
        var a = FileAnalysis(path: rec.path, modified: rec.modified, sizeBytes: rec.sizeBytes, artist: rec.artist, title: rec.title,
                             durationSec: rec.durationSec, bpm: nil, bpmAmbiguous: false, libraryTrackID: libraryTrackID, analyzedAt: Date())
        // Up to 2 minutes from 25% in: past the DJ intro, into the main groove.
        guard let (samples, sr) = BPMTool.decodeMono(url: url, maxSeconds: 120, startFraction: 0.25) else { return a }
        if let t = BPMTool.estimateTempo(samples: samples, sampleRate: sr) {
            a.bpm = t.bpm
            a.bpmAmbiguous = t.ambiguous
            a.bpmAlternate = t.alternate
        }
        if let k = detectKey(samples: samples, sampleRate: sr) {
            a.key = k.name
            a.camelot = k.camelot
            a.keyConfidence = k.confidence
        }
        return a
    }

    // MARK: Key detection (chromagram + Krumhansl–Kessler key profiles)

    static let pitchNames = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    static func detectKey(samples: [Float], sampleRate sr: Double) -> (name: String, camelot: String, confidence: Double)? {
        let fftSize = 8192, hop = 4096
        guard samples.count > fftSize * 4,
              let dft = try? vDSP.DiscreteFourierTransform(count: fftSize, direction: .forward, transformType: .complexComplex, ofType: Float.self) else { return nil }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        let zeros = [Float](repeating: 0, count: fftSize)

        // Bin → pitch class for 55 Hz (A1) … 2 kHz; lower bins are too coarse, higher ones mostly harmonics/hats.
        let binHz = sr / Double(fftSize)
        let lo = Int((55 / binHz).rounded(.up)), hi = min(fftSize / 2 - 1, Int(2000 / binHz))
        let pcOfBin: [Int] = (0...hi).map { k in
            guard k >= lo else { return -1 }
            let midi = 69 + 12 * log2(Double(k) * binHz / 440)
            return ((Int(midi.rounded()) % 12) + 12) % 12
        }

        var chroma = [Double](repeating: 0, count: 12)
        var start = 0
        while start + fftSize <= samples.count {
            let frame = vDSP.multiply(Array(samples[start..<start + fftSize]), window)
            let (re, im) = dft.transform(real: frame, imaginary: zeros)
            var frameChroma = [Double](repeating: 0, count: 12)
            for k in lo...hi { frameChroma[pcOfBin[k]] += Double((re[k] * re[k] + im[k] * im[k]).squareRoot()) }
            let total = frameChroma.reduce(0, +)
            if total > 0 { for i in 0..<12 { chroma[i] += frameChroma[i] / total } }   // each frame votes equally
            start += hop
        }
        guard chroma.reduce(0, +) > 0 else { return nil }

        func corr(_ x: [Double], _ y: [Double]) -> Double {
            let mx = x.reduce(0, +) / 12, my = y.reduce(0, +) / 12
            var num = 0.0, dx = 0.0, dy = 0.0
            for i in 0..<12 { num += (x[i] - mx) * (y[i] - my); dx += pow(x[i] - mx, 2); dy += pow(y[i] - my, 2) }
            return num / max(1e-9, (dx * dy).squareRoot())
        }
        var scores: [(tonic: Int, minor: Bool, r: Double)] = []
        for tonic in 0..<12 {
            let rotated = (0..<12).map { chroma[($0 + tonic) % 12] }
            scores.append((tonic, false, corr(rotated, majorProfile)))
            scores.append((tonic, true, corr(rotated, minorProfile)))
        }
        scores.sort { $0.r > $1.r }
        let best = scores[0]
        return ("\(pitchNames[best.tonic]) \(best.minor ? "minor" : "major")", camelot(tonic: best.tonic, minor: best.minor), max(0, best.r - scores[1].r))
    }

    /// C major = 8B, each fifth up adds 1; a minor key shares the number of its relative major (A minor = 8A).
    static func camelot(tonic: Int, minor: Bool) -> String {
        let majorTonic = minor ? (tonic + 3) % 12 : tonic
        let n = ((7 * majorTonic) % 12 + 7) % 12 + 1
        return "\(n)\(minor ? "A" : "B")"
    }

    /// Keys that mix cleanly with `c`: same key, ±1 on the wheel, and the relative major/minor.
    static func compatible(_ c: String) -> Set<String> {
        guard let n = Int(c.dropLast()), let letter = c.last else { return [] }
        let other: Character = letter == "A" ? "B" : "A"
        let up = n % 12 + 1, down = (n + 10) % 12 + 1
        return ["\(n)\(letter)", "\(up)\(letter)", "\(down)\(letter)", "\(n)\(other)"]
    }

    // MARK: CLI

    static func runCLI(paths: [String]) async {
        let roots = paths.isEmpty ? [LibraryStore.tracksDir] : paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        var files: [URL] = []
        for r in roots {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: r.path, isDirectory: &isDir), !isDir.boolValue { files.append(r) } else { files += findAudioFiles(in: r) }
        }
        var cache = loadCache()
        for f in files {
            let rec = await readTrack(f)
            let a = isFresh(cache[f.path], rec) ? cache[f.path]! : analyze(rec, libraryTrackID: nil)
            cache[f.path] = a
            let bpm = a.bpm.map { String(format: "%6.1f", $0) + (a.bpmAmbiguous ? "?" : " ") } ?? "     – "
            print("\(bpm)  \((a.camelot ?? "–").padding(toLength: 4, withPad: " ", startingAt: 0))  \((a.key ?? "").padding(toLength: 9, withPad: " ", startingAt: 0))  \(f.lastPathComponent)")
        }
        saveCache(cache)
    }
}
