import Foundation

// Tracks/ is organised into one folder per genre family (Afro House, House, Desi Hip-Hop, Bollywood …, see
// GenreTool.rules), with "Unsorted" for tracks whose genre isn't known yet. Energy isn't a folder: it's written
// into each file's comment as "Energy 1–10" (Rekordbox shows it), ranked across the whole library like Mixed In
// Key's scale — Energy 1 = your calmest tenth, Energy 10 = your hardest.
// New downloads are filed straight into their genre folder; "Organise folders" (and every genre rebuild) moves
// whatever is in the wrong place.

extension LibraryStore {
    static let unsortedFolder = "Unsorted"

    /// Where a family with under `minFolder` tracks goes instead, so the folder list stays short on a CDJ.
    /// It gets its own folder again once it grows.
    static let minFolder = 5
    static let smallFolderHome: [String: String] = [
        "K-Pop": "Pop", "Afrobeats": "Afro House", "Amapiano": "Afro House", "Brazilian Funk": "Bass",
        "Reggae & Dancehall": "Latin", "Soundtrack": "Bollywood", "Jazz & Blues": "R&B & Soul", "Classical": "Chill & Downtempo",
        "Rock": "Indie & Alternative", "Techno": "House", "Drum & Bass": "Bass", "UK Garage": "House", "Punjabi": "Bollywood",
        "Desi Indie": "Bollywood", "Desi Hip-Hop": "Hip-Hop & Rap", "Afro House": "House", "Latin": "Pop", "Electronic": "House",
    ]

    private func family(_ id: String) -> String? {
        let g = state.genreOverrides[id] ?? genres[id]?.genre
        return g.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Tracks per family in the crate (cached until the crate or genres change).
    private var familyCounts: [String: Int] {
        let key = state.tracks.count &+ genres.count &* 31 &+ state.genreOverrides.count &* 7
        if let c = familyCountCache, c.key == key { return c.counts }
        var counts: [String: Int] = [:]
        for (id, st) in state.tracks where st.status == .downloaded { if let f = family(id) { counts[f, default: 0] += 1 } }
        familyCountCache = (key, counts)
        return counts
    }

    /// The folder a track is filed under (your own genre choice wins); small families join a bigger one.
    func folderGenre(_ id: String) -> String {
        guard var g = family(id) else { return Self.unsortedFolder }
        let counts = familyCounts
        var hops = 0
        while (counts[g] ?? 0) < Self.minFolder, let home = Self.smallFolderHome[g], hops < 4 { g = home; hops += 1 }
        return g.replacingOccurrences(of: "/", with: "&")   // a folder name can't contain "/"
    }

    /// 1–10 from Essentia's energy, by rank within the library (the raw values bunch up between 0.6 and 0.9).
    func energyLevel(_ energy: Double?) -> Int? {
        guard let e = energy else { return nil }
        let all = energyRanks
        guard !all.isEmpty else { return nil }
        var lo = 0, hi = all.count
        while lo < hi { let m = (lo + hi) / 2; if all[m] < e { lo = m + 1 } else { hi = m } }
        return min(10, Int(Double(lo) / Double(all.count) * 10) + 1)
    }

    /// Sorted energies of every analysed file (cached; rebuilt when the analysis count changes).
    var energyRanks: [Double] {
        if let c = energyRankCache, c.count == analysis.count { return c.values }
        let v = analysis.values.compactMap(\.energy).sorted()
        energyRankCache = (analysis.count, v)
        return v
    }

    func genreFolder(_ id: String) -> URL { Self.tracksDir.appendingPathComponent(folderGenre(id), isDirectory: true) }

    /// Where a track's file belongs: Tracks/<genre>/<Artist - Title>.<ext>.
    func destination(for id: String, ext: String, avoiding current: String? = nil) -> URL? {
        guard let t = track(id) else { return nil }
        let dir = genreFolder(id)
        var dest = dir.appendingPathComponent(t.fileName).appendingPathExtension(ext.lowercased())
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path), dest.path != current {
            dest = dir.appendingPathComponent("\(t.fileName) (\(n))").appendingPathExtension(ext.lowercased()); n += 1
        }
        return dest
    }

    /// Moves every crate file inside Tracks/ into its genre folder. Files elsewhere on the Mac are left alone.
    /// Returns how many moved.
    @discardableResult
    func organiseFolders() -> Int {
        let fm = FileManager.default
        let root = Self.tracksDir.standardizedFileURL.path + "/"
        var moved = 0
        for (id, st) in state.tracks where st.status == .downloaded {
            guard let path = st.localPath, path.hasPrefix(root), fm.fileExists(atPath: path) else { continue }
            let want = genreFolder(id).standardizedFileURL.path + "/"
            if path.hasPrefix(want), !path.dropFirst(want.count).contains("/") { continue }   // already in place
            guard let dest = destination(for: id, ext: (path as NSString).pathExtension, avoiding: path) else { continue }
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(atPath: path, toPath: dest.path)
            } catch {
                log("organise", id, "couldn't move \((path as NSString).lastPathComponent): \(error.localizedDescription)")
                continue
            }
            var s = st
            s.localPath = dest.path
            state.tracks[id] = s
            if var a = analysis.removeValue(forKey: path) { a.path = dest.path; analysis[dest.path] = a }
            if let q = quality.removeValue(forKey: path) { quality[dest.path] = q }
            moved += 1
        }
        // Folders left empty (a genre that no longer has tracks) go away.
        if let dirs = try? fm.contentsOfDirectory(at: Self.tracksDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for d in dirs where (try? d.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let items = (try? fm.contentsOfDirectory(atPath: d.path))?.filter { $0 != ".DS_Store" } ?? []
                if items.isEmpty { try? fm.removeItem(at: d) }
            }
        }
        if moved > 0 {
            Analyzer.saveCache(analysis)
            if let d = try? JSONEncoder().encode(quality) { try? d.write(to: Self.qualityCacheFile, options: .atomic) }
            log("organise", nil, "filed \(moved) tracks into genre folders")
            save()
        }
        return moved
    }

    /// Genres from Deezer + Last.fm + playlists + artists, then folders and "Energy N" comments brought up to date.
    func rebuildGenresAndOrganise() async {
        guard busy == nil else { return }
        busy = "Working out genres (Deezer, Last.fm)…"
        do {
            try await Task.detached(priority: .userInitiated) { try await GenreTool.run(args: []) }.value
            genres = GenreTool.load()
        } catch {
            log("genres", nil, "genre update failed: \(error.localizedDescription)")
        }
        busy = "Filing tracks into genre folders…"
        let moved = organiseFolders()
        busy = nil
        log("organise", nil, "genres updated; \(moved) tracks moved")
        await writeTags()   // genre + "Energy N" into every file
    }
}
