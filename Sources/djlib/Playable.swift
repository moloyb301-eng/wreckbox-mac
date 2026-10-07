import Foundation

// Files Rekordbox and CDJs can't play (OGG Vorbis, Opus, WMA, Dolby surround E-AC-3 / AC-3) are kept as they are:
// the user doesn't want anything converted to FLAC (2026-10-07). The lossless upgrade pass (slsk-sync) looks for a
// real FLAC of them instead. _cache/converted.json lists files converted before that decision (empty once reverted).

enum Playable {
    static let ffmpeg = [AppPaths.binDir?.appendingPathComponent("ffmpeg").path, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
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
}

extension LibraryStore {
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
