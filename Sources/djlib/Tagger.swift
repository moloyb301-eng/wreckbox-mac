import Foundation

// Writes WreckBox's data (Spotify title / artists / album / year, genre, BPM, key, ISRC, cover) into the
// audio files via analysis/tagger.py (mutagen), so Rekordbox sees the same information as the app.

struct TagJob: Encodable {
    var path: String
    var title: String
    var artists: [String]
    var album: String?
    var year: String?
    var genre: String?
    var bpm: Double?
    var key: String?
    var isrc: String?
    var cover: String?
}

struct TagResult: Decodable {
    var path: String
    var ok: Bool
    var cover: Bool?
    var error: String?
}

enum Tagger {
    static var script: URL { AppPaths.repo.appendingPathComponent("analysis/tagger.py") }
    static var available: Bool { AppPaths.essentiaAvailable && FileManager.default.fileExists(atPath: script.path) }

    /// Heavy (copies each file); call off the main thread.
    static func write(_ jobs: [TagJob], progress: ((Int) -> Void)? = nil) -> [TagResult] {
        guard available, !jobs.isEmpty, let input = try? JSONEncoder().encode(jobs) else { return [] }
        let p = Process()
        p.executableURL = AppPaths.essentiaPython
        p.arguments = [script.path]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        var results: [TagResult] = []
        var buffer = Data()
        while case let chunk = stdout.fileHandleForReading.availableData, !chunk.isEmpty {
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<nl]
                buffer.removeSubrange(...nl)
                if let r = try? JSONDecoder().decode(TagResult.self, from: line) {
                    results.append(r)
                    progress?(results.count)
                }
            }
        }
        p.waitUntilExit()
        return results
    }
}

extension LibraryStore {
    /// The tag job for a track that has a file on disk.
    func tagJob(_ id: String) -> TagJob? {
        guard let r = row(id), let path = r.state?.localPath, FileManager.default.fileExists(atPath: path) else { return nil }
        let t = r.track
        let cached = ArtworkLoader.dir.appendingPathComponent(ArtworkLoader.fileStem(t.id) + ".jpg").path
        return TagJob(path: path, title: t.title, artists: t.artists, album: t.album, year: t.year,
                      genre: r.genre.isEmpty ? nil : r.genre, bpm: r.file?.bpm, key: r.file?.key, isrc: t.isrc,
                      cover: t.artworkURL ?? (FileManager.default.fileExists(atPath: cached) ? cached : nil))
    }

    /// Writes tags into the files of the given tracks (all downloaded tracks when `ids` is nil).
    func writeTags(_ ids: [String]? = nil) async {
        guard Tagger.available, busy == nil else { return }
        let targets = ids ?? (library?.tracks ?? []).filter { state.tracks[$0.id]?.status == .downloaded }.map(\.id)
        let jobs = targets.compactMap { tagJob($0) }
        guard !jobs.isEmpty else { return }
        busy = "Writing tags 0/\(jobs.count)…"
        let total = jobs.count
        let results = await Task.detached(priority: .utility) {
            Tagger.write(jobs) { n in Task { @MainActor in self.busy = "Writing tags \(n)/\(total)…" } }
        }.value
        busy = nil
        let failed = results.filter { !$0.ok }
        for f in failed { log("tag failed", nil, "\((f.path as NSString).lastPathComponent): \(f.error ?? "unknown error")") }
        log("tags written", ids?.count == 1 ? ids?.first : nil,
            ids?.count == 1 ? "\(describe(ids![0])) — file updated" : "\(results.count - failed.count) files updated, \(failed.count) failed")
        // Tagging rewrote the files; refresh the analysis cache's size/date so they aren't re-analysed needlessly.
        for r in results where r.ok {
            if var a = analysis[r.path], let attrs = try? FileManager.default.attributesOfItem(atPath: r.path) {
                a.sizeBytes = (attrs[.size] as? NSNumber)?.int64Value ?? a.sizeBytes
                a.modified = attrs[.modificationDate] as? Date
                analysis[r.path] = a
            }
        }
        Analyzer.saveCache(analysis)
        save()
    }
}
