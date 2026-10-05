import AVFoundation
import Accelerate
import Foundation

// BPM lookup: Deezer's catalogue BPM when it has one, otherwise tempo estimated from the
// 30-second iTunes Store preview (downloaded to a temp file, analysed, deleted). Results are cached.

struct BPMResult: Codable {
    var bpm: Double?
    var source: String          // "deezer", "estimated", "not found", "error: …"
    var confidence: Double?     // estimated only: peak strength vs. average (higher = steadier beat)
    var ambiguous: Bool         // estimated only: half/double tempo scored nearly as high
    var alternate: Double?      // the competing half/double tempo when ambiguous
    var deezerID: Int?
}

enum BPMTool {
    static let cacheFile = libraryRoot.appendingPathComponent("_cache/bpm.json")

    static func run(args: [String]) async throws {
        func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let wanted = (opt("--playlists") ?? "Liked Songs").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let lo = Double(opt("--min") ?? "") ?? 0, hi = Double(opt("--max") ?? "") ?? 999

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let lib = try dec.decode(Library.self, from: Data(contentsOf: libraryRoot.appendingPathComponent("library.json")))
        let known = Set(lib.playlists.map(\.name))
        for w in wanted where !known.contains(w) { throw SpotifyError.auth("no playlist named \"\(w)\" in library.json") }

        // Unique tracks across the chosen playlists (library.json is already de-duplicated by ISRC / id).
        let tracks = lib.tracks.filter { !Set($0.playlists).isDisjoint(with: wanted) }
        var cache = (try? JSONDecoder().decode([String: BPMResult].self, from: Data(contentsOf: cacheFile))) ?? [:]
        let todo = tracks.filter { cache[$0.id] == nil }
        log("\(tracks.count) unique tracks in \(wanted.joined(separator: ", ")); \(tracks.count - todo.count) cached, \(todo.count) to look up")

        // Small worker pool; Deezer allows ~50 requests / 5 s.
        var done = 0
        try await withThrowingTaskGroup(of: (String, BPMResult).self) { group in
            var it = todo.makeIterator()
            func addNext() { if let t = it.next() { group.addTask { (t.id, await lookup(t)) } } }
            for _ in 0..<3 { addNext() }
            while let (id, r) = try await group.next() {
                cache[id] = r
                done += 1
                if done % 25 == 0 || done == todo.count {
                    log("  \(done)/\(todo.count)")
                    try saveCache(cache)
                }
                addNext()
            }
        }
        try saveCache(cache)

        // Report
        let rows = tracks.compactMap { t -> (LibraryTrack, BPMResult)? in cache[t.id].map { (t, $0) } }
        let inRange = rows.filter { ($0.1.bpm ?? -1) >= lo && ($0.1.bpm ?? -1) <= hi }.sorted { $0.1.bpm! < $1.1.bpm! }
        let maybe = rows.filter { r in
            guard let b = r.1.bpm, !(b >= lo && b <= hi), r.1.ambiguous, let alt = r.1.alternate else { return false }
            return alt >= lo && alt <= hi
        }.sorted { $0.1.alternate! < $1.1.alternate! }
        let missing = rows.filter { $0.1.bpm == nil }

        let name = "BPM \(Int(lo))-\(Int(hi)) – " + wanted.joined(separator: " + ")
        var csv = "#,bpm,artist,title,playlists,bpm_source,confidence,check_half_double,duration,isrc\n"
        for (i, (t, r)) in inRange.enumerated() {
            let dur = t.durationMs.map { String(format: "%d:%02d", $0 / 60000, $0 / 1000 % 60) }
            let row: [String?] = [String(i + 1), String(format: "%.1f", r.bpm!), t.artists.joined(separator: ", "), t.title,
                                  t.playlists.filter(wanted.contains).joined(separator: " | "), r.source,
                                  r.confidence.map { String(format: "%.2f", $0) },
                                  r.ambiguous ? "maybe \(Int(r.alternate!.rounded()))" : "", dur, t.isrc]
            csv += row.map(csvField).joined(separator: ",") + "\n"
        }
        let out = libraryRoot.appendingPathComponent("Playlists/\(safeFileName(name)).csv")
        try csv.write(to: out, atomically: true, encoding: .utf8)

        var check = "bpm_detected,could_be,artist,title,playlists\n"
        for (t, r) in maybe {
            check += [String(format: "%.1f", r.bpm!), String(format: "%.1f", r.alternate!), t.artists.joined(separator: ", "), t.title,
                      t.playlists.filter(wanted.contains).joined(separator: " | ")].map(csvField).joined(separator: ",") + "\n"
        }
        let checkOut = libraryRoot.appendingPathComponent("Playlists/\(safeFileName(name)) – check.csv")
        try check.write(to: checkOut, atomically: true, encoding: .utf8)

        let bySource = Dictionary(grouping: rows, by: { $0.1.source.hasPrefix("error") ? "error" : $0.1.source }).mapValues(\.count)
        print("\nBPM found for \(rows.count - missing.count)/\(rows.count) tracks  " + bySource.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
        print("In \(Int(lo))–\(Int(hi)) BPM: \(inRange.count) tracks (\(inRange.filter { $0.1.ambiguous }.count) flagged to double-check)")
        print("Outside range but possibly half/double-time into it: \(maybe.count)")
        print("Wrote \(out.path)\n      \(checkOut.path)")
    }

    // MARK: Lookup

    static func lookup(_ t: LibraryTrack) async -> BPMResult {
        do {
            var track: [String: Any]? = nil
            if let isrc = t.isrc { track = try await deezer("track/isrc:\(isrc)") }
            if track?["id"] == nil {
                let q = "artist:\"\(t.artists.first ?? "")\" track:\"\(t.title)\""
                let hit = (try await deezer("search?q=" + q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!))["data"] as? [[String: Any]]
                if let id = hit?.first?["id"] as? Int { track = try await deezer("track/\(id)") }
            }
            guard let tr = track, let did = tr["id"] as? Int else { return await estimateFromITunes(t, deezerID: nil) }
            if let b = (tr["bpm"] as? NSNumber)?.doubleValue, b > 0 {
                return BPMResult(bpm: (b * 10).rounded() / 10, source: "deezer", ambiguous: false, deezerID: did)
            }
            return await estimateFromITunes(t, deezerID: did)
        } catch {
            return BPMResult(bpm: nil, source: "error: \(error.localizedDescription)", ambiguous: false)
        }
    }

    /// Finds the track on the iTunes Store (artist + title, duration within 4 s), downloads its
    /// 30 s preview to a temp file, estimates tempo, and deletes the file.
    static func estimateFromITunes(_ t: LibraryTrack, deezerID: Int?) async -> BPMResult {
        do {
            var c = URLComponents(string: "https://itunes.apple.com/search")!
            c.queryItems = [.init(name: "term", value: "\(t.artists.first ?? "") \(t.title)"), .init(name: "entity", value: "song"), .init(name: "limit", value: "10")]
            var results: [[String: Any]] = []
            for attempt in 0..<4 {
                let (data, resp) = try await URLSession.shared.data(from: c.url!)
                if (resp as? HTTPURLResponse)?.statusCode == 403 || (resp as? HTTPURLResponse)?.statusCode == 429 {
                    try await Task.sleep(nanoseconds: UInt64(5_000_000_000 << attempt)); continue   // iTunes throttles ~20 req/min
                }
                results = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["results"] as? [[String: Any]] ?? []
                break
            }
            let target = t.durationMs ?? 0
            let match = results.filter { $0["previewUrl"] is String }
                .min { abs(($0["trackTimeMillis"] as? Int ?? 0) - target) < abs(($1["trackTimeMillis"] as? Int ?? 0) - target) }
            guard let m = match, target == 0 || abs((m["trackTimeMillis"] as? Int ?? 0) - target) < 4000,
                  let url = URL(string: m["previewUrl"] as! String) else {
                return BPMResult(bpm: nil, source: "not found", ambiguous: false, deezerID: deezerID)
            }
            let (tmp, _) = try await URLSession.shared.download(from: url)
            let file = tmp.deletingPathExtension().appendingPathExtension("m4a")
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: tmp, to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            guard var est = estimateTempo(url: file) else { return BPMResult(bpm: nil, source: "error: undecodable preview", ambiguous: false, deezerID: deezerID) }
            est.deezerID = deezerID
            return est
        } catch {
            return BPMResult(bpm: nil, source: "error: \(error.localizedDescription)", ambiguous: false, deezerID: deezerID)
        }
    }

    static func deezer(_ path: String) async throws -> [String: Any] {
        for attempt in 0..<4 {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "https://api.deezer.com/\(path)")!)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let err = json["error"] as? [String: Any], (err["code"] as? Int) == 4 {   // quota exceeded
                try await Task.sleep(nanoseconds: UInt64(1_000_000_000 << attempt)); continue
            }
            return json
        }
        return [:]
    }

    // MARK: Tempo estimation (spectral-flux onset envelope + autocorrelation with a tempo prior)

    static func estimateTempo(url: URL) -> BPMResult? {
        guard let (mono, sr) = decodeMono(url: url) else { return nil }
        return estimateTempo(samples: mono, sampleRate: sr)
    }

    /// Decodes to mono float. With `maxSeconds`, takes a window starting `startFraction` into the file
    /// (skips long intros so DJ edits are judged on the body of the track).
    static func decodeMono(url: URL, maxSeconds: Double? = nil, startFraction: Double = 0) -> ([Float], Double)? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let sr = file.processingFormat.sampleRate
        var count = file.length
        if let m = maxSeconds, Double(file.length) / sr > m {
            count = AVAudioFramePosition(m * sr)
            file.framePosition = min(AVAudioFramePosition(Double(file.length) * startFraction), file.length - count)
        }
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)),
              (try? file.read(into: buf, frameCount: AVAudioFrameCount(count))) != nil, let ch = buf.floatChannelData, buf.frameLength > 0 else { return nil }
        let n = Int(buf.frameLength)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<Int(buf.format.channelCount) { vDSP.add(mono, UnsafeBufferPointer(start: ch[c], count: n), result: &mono) }
        return (mono, sr)
    }

    static func estimateTempo(samples mono: [Float], sampleRate sr: Double) -> BPMResult? {
        let n = mono.count
        let fftSize = 2048, hop = 512
        guard n > fftSize * 4, let dft = try? vDSP.DiscreteFourierTransform(count: fftSize, direction: .forward, transformType: .complexComplex, ofType: Float.self) else { return nil }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        let bins = min(fftSize / 2, Int(8000 / sr * Double(fftSize)))
        let zeros = [Float](repeating: 0, count: fftSize)
        var prev = [Float](repeating: 0, count: bins)
        var onset: [Float] = []
        var start = 0
        while start + fftSize <= n {
            let frame = vDSP.multiply(Array(mono[start..<start + fftSize]), window)
            let (re, im) = dft.transform(real: frame, imaginary: zeros)
            var mag = [Float](repeating: 0, count: bins)
            for k in 0..<bins { mag[k] = log1p(1000 * (re[k] * re[k] + im[k] * im[k]).squareRoot()) }
            onset.append(zip(mag, prev).reduce(0) { $0 + max(0, $1.0 - $1.1) })
            prev = mag
            start += hop
        }
        let fps = sr / Double(hop)
        // Remove slow trend (~1 s moving average) so sustained loudness doesn't dominate.
        let w = Int(fps)
        var env = [Float](repeating: 0, count: onset.count)
        var acc: Float = 0
        for i in 0..<onset.count {
            acc += onset[i]; if i >= w { acc -= onset[i - w] }
            env[i] = max(0, onset[i] - acc / Float(min(i + 1, w)))
        }

        func ac(_ lag: Double) -> Double {
            let l0 = Int(lag), f = lag - Double(l0)
            guard l0 + 1 < env.count * 3 / 4 else { return 0 }
            func at(_ l: Int) -> Double {
                var s: Float = 0
                vDSP_dotpr(env, 1, Array(env[l...]), 1, &s, vDSP_Length(env.count - l))
                return Double(s) / Double(env.count - l)
            }
            return at(l0) * (1 - f) + at(l0 + 1) * f
        }

        var cache: [Double: Double] = [:]
        func strength(_ bpm: Double) -> Double {
            if let v = cache[bpm] { return v }
            let lag = fps * 60 / bpm
            // A real beat repeats at 1, 2, 3 and 4 beats; a triplet / off-beat lag only lines up on some of them.
            let v = (1...4).map { ac(Double($0) * lag) }.reduce(0, +) / 4
            cache[bpm] = v
            return v
        }
        func prior(_ bpm: Double) -> Double { exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2)) }

        let grid = stride(from: 60.0, through: 200.0, by: 0.25).map { $0 }
        let scored = grid.map { ($0, strength($0) * prior($0)) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        let mean = scored.map(\.1).reduce(0, +) / Double(scored.count)

        // Octave check: does half or double tempo have nearly as much raw pulse strength?
        let alts = [best.0 / 2, best.0 * 2, best.0 * 2 / 3, best.0 * 3 / 2].filter { $0 >= 60 && $0 <= 200 }
        let rival = alts.map { a in (a, (stride(from: a - 1, through: a + 1, by: 0.25).map(strength).max() ?? 0)) }.max { $0.1 < $1.1 }
        let ambiguous = rival.map { $0.1 >= 0.95 * strength(best.0) } ?? false

        return BPMResult(bpm: (best.0 * 10).rounded() / 10, source: "estimated", confidence: best.1 / mean,
                         ambiguous: ambiguous, alternate: ambiguous ? rival!.0 : nil)
    }

    static func saveCache(_ c: [String: BPMResult]) throws {
        try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(c).write(to: cacheFile)
    }

    static func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
}
