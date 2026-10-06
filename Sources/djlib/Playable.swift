import Foundation

// Rekordbox and CDJs can't play OGG Vorbis, Opus, WMA or Dolby surround (E-AC-3 / AC-3). Those are converted to
// FLAC (stereo, 16-bit) with ffmpeg: FLAC stores the decoded audio exactly, so nothing more is lost on top of the
// source's own quality. Done for new downloads as they arrive, and for files already in the crate.

enum Playable {
    static let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    static let unplayableExtensions: Set<String> = ["ogg", "oga", "opus", "webm", "wma"]

    /// Needs converting before Rekordbox can use it.
    static func needsConversion(_ path: String, quality: FileQuality?) -> Bool {
        if unplayableExtensions.contains((path as NSString).pathExtension.lowercased()) { return true }
        if let q = quality, q.channels != nil { return q.unplayable }
        return FileQuality.probe(path)?.unplayable ?? false   // older cache entries don't know the channel count
    }

    /// Track id → what a converted file was ({"codec": "DOLBY" | "OGG" …, "kbps": 768}); _cache/converted.json.
    static var convertedFile: URL { libraryRoot.appendingPathComponent("_cache/converted.json") }
    static var converted: [String: [String: Any]] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: convertedFile))) as? [String: [String: Any]] ?? [:]
    }

    /// Notes the source format of `path` (before converting it) for track `id`.
    static func recordSource(_ path: String, id: String) {
        let q = FileQuality.probe(path)
        // A lossless surround source mixed down to stereo FLAC is still truly lossless: nothing to note.
        if q?.lossless == true, q?.codec != "E-AC3", q?.codec != "AC3" { return }
        let ext = (path as NSString).pathExtension.uppercased()
        let codec = q?.unplayable == true ? "DOLBY" : (q?.codec ?? ext)
        var all = converted
        all[id] = ["codec": codec == "M4A" ? ext : codec, "kbps": q?.kbps as Any]
        if let d = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: convertedFile, options: .atomic) }
    }

    /// Converts to a FLAC next to the original; returns its path (the original is left for the caller).
    static func convertToFLAC(_ path: String) -> String? {
        guard let ffmpeg else { return nil }
        // Never over another file: a different "Name.flac" already next to it gets "Name (2).flac".
        let stem = (path as NSString).deletingPathExtension
        var out = stem + ".flac", n = 2
        while out != path, FileManager.default.fileExists(atPath: out) { out = "\(stem) (\(n)).flac"; n += 1 }
        // Keep 24-bit sources 24-bit (best quality); everything else is 16-bit.
        let bits = FileQuality.probe(path)?.bits ?? 16
        let depth = bits > 16 ? ["-sample_fmt", "s32", "-bits_per_raw_sample", "24"] : ["-sample_fmt", "s16"]
        let tmp = out + ".part.flac"
        try? FileManager.default.removeItem(atPath: tmp)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-y", "-i", path, "-vn", "-map", "0:a:0", "-ac", "2", "-c:a", "flac"] + depth + [tmp]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: tmp) else { try? FileManager.default.removeItem(atPath: tmp); return nil }
        if out == path { try? FileManager.default.removeItem(atPath: out) }   // a surround .flac replaced in place
        do { try FileManager.default.moveItem(atPath: tmp, toPath: out) } catch { return nil }
        return out
    }
}

extension LibraryStore {
    /// Converts crate files Rekordbox can't play to FLAC, re-points the track at it, re-tags it and moves the old
    /// file to the Trash. Returns how many were converted.
    @discardableResult
    func convertUnplayable() async -> Int {
        var done = 0
        for (id, st) in state.tracks where st.status == .downloaded {
            guard let path = st.localPath, FileManager.default.fileExists(atPath: path),
                  Playable.needsConversion(path, quality: quality[path]) else { continue }
            Playable.recordSource(path, id: id)
            guard let flac = await Task.detached(priority: .utility, operation: { Playable.convertToFLAC(path) }).value else {
                log("convert", id, "couldn't convert \((path as NSString).lastPathComponent) to FLAC")
                continue
            }
            var s = st
            s.localPath = flac
            state.tracks[id] = s
            if var a = analysis.removeValue(forKey: path) { a.path = flac; analysis[flac] = a }
            quality[path] = nil
            // A surround .flac is replaced in place (same name); only a different original goes to the Trash.
            if flac != path { try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
            log("convert", id, "\(describe(id)): \((path as NSString).pathExtension.uppercased()) → FLAC so Rekordbox can play it")
            save()
            await analyseAndTag(id, path: flac)
            done += 1
        }
        if done > 0 { Analyzer.saveCache(analysis) }
        return done
    }

    /// Full analysis (BPM, key, energy) of one file, then its tags (incl. "Energy N") and cover.
    func analyseAndTag(_ id: String, path: String) async {
        let rec = await readTrack(URL(fileURLWithPath: path))
        analysis[path] = await Task.detached(priority: .utility) { Analyzer.analyze(rec, libraryTrackID: id) }.value
        Analyzer.saveCache(analysis)
        if let job = tagJob(id) { _ = await Task.detached(priority: .utility) { Tagger.write([job]) }.value }
    }

    /// Crate files with no energy yet (e.g. a format the analyser couldn't read before it was converted).
    func analyseMissing() async {
        for (id, st) in state.tracks where st.status == .downloaded {
            guard let p = st.localPath, FileManager.default.fileExists(atPath: p), analysis[p]?.energy == nil else { continue }
            await analyseAndTag(id, path: p)
            log("analyse", id, "analysed \(describe(id)) (energy was missing)")
        }
    }
}
