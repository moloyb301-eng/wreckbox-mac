import Foundation

// Builds the master catalog from the Spotify export: one entry per unique recording,
// tagged with every playlist it appears in. Files get attached to entries in later steps.

struct LibraryTrack: Codable {
    var id: String              // ISRC when available, else spotify:<id>, else normalized artist+title
    var artists: [String]
    var title: String
    var album: String?
    var year: String?
    var isrc: String?
    var spotifyIDs: [String]
    var durationMs: Int?
    var playlists: [String]     // "Liked Songs" + playlist names, in first-seen order
    var firstAdded: String?
    var fileName: String        // target "Artist - Title.ext" stem for when the file arrives
    var localPath: String?      // filled in by the matcher
    var status: String          // "missing" until a file is matched
    var artworkURL: String?     // Spotify album cover
}

struct LibraryPlaylist: Codable {
    var name: String
    var spotifyID: String?
    var collaborative: Bool
    var trackIDs: [String]      // ordered, references LibraryTrack.id
}

struct Library: Codable {
    var builtAt: Date
    var spotifyUser: String
    var tracks: [LibraryTrack]
    var playlists: [LibraryPlaylist]
}

let libraryRoot = home.appendingPathComponent("Music/DJ Library")

func buildLibrary() throws {
    let src = SpotifyImport.exportDir.appendingPathComponent("spotify.json")
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    let export = try dec.decode(SpotifyExport.self, from: Data(contentsOf: src))

    // Personal sources only: Liked Songs + playlists you own or collaborate on that were readable.
    var sources: [(name: String, id: String?, collab: Bool, tracks: [SpotifyTrack])] = [("Liked Songs", nil, false, export.likedSongs)]
    var seenNames: [String: Int] = ["Liked Songs": 1]
    for p in export.playlists where p.skippedReason == nil && (p.ownedByMe || p.collaborative) {
        var name = p.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "Untitled" }
        seenNames[name, default: 0] += 1
        if seenNames[name]! > 1 { name += " (\(seenNames[name]!))" }
        sources.append((name, p.id, p.collaborative, p.tracks))
    }

    var tracks: [LibraryTrack] = []
    var index: [String: Int] = [:]       // any known key -> tracks index
    var playlists: [LibraryPlaylist] = []
    var skippedLocal = 0

    for s in sources {
        var ids: [String] = []
        for t in s.tracks {
            if t.isLocal || t.name.isEmpty { skippedLocal += 1; continue }
            let fuzzy = "na:" + normalized(t.artists.first ?? "") + "|" + normalized(t.name) + "|" + String((t.durationMs ?? 0) / 5000)
            let keys = [t.isrc.map { "isrc:" + $0.uppercased() }, t.spotifyID.map { "sp:" + $0 }, fuzzy].compactMap { $0 }
            if let i = keys.lazy.compactMap({ index[$0] }).first {
                if let sid = t.spotifyID, !tracks[i].spotifyIDs.contains(sid) { tracks[i].spotifyIDs.append(sid) }
                if !tracks[i].playlists.contains(s.name) { tracks[i].playlists.append(s.name) }
                if let a = t.addedAt, a < (tracks[i].firstAdded ?? "~") { tracks[i].firstAdded = a }
                if tracks[i].artworkURL == nil { tracks[i].artworkURL = t.artworkURL }
                keys.forEach { index[$0] = i }
                ids.append(tracks[i].id)
                continue
            }
            let id = t.isrc?.uppercased() ?? t.spotifyID.map { "spotify:" + $0 } ?? fuzzy
            tracks.append(LibraryTrack(
                id: id, artists: t.artists, title: t.name, album: t.album,
                year: t.releaseDate.map { String($0.prefix(4)) }, isrc: t.isrc?.uppercased(),
                spotifyIDs: t.spotifyID.map { [$0] } ?? [], durationMs: t.durationMs,
                playlists: [s.name], firstAdded: t.addedAt,
                fileName: safeFileName("\(t.artists.joined(separator: ", ")) - \(t.name)"),
                localPath: nil, status: "missing", artworkURL: t.artworkURL))
            keys.forEach { index[$0] = tracks.count - 1 }
            ids.append(id)
        }
        playlists.append(LibraryPlaylist(name: s.name, spotifyID: s.id, collaborative: s.collab, trackIDs: ids))
    }

    // Folder layout: Tracks/ holds one copy of each file; Playlists/ will hold generated .m3u8 lists.
    for dir in ["Tracks", "Playlists", "_inbox"] {
        try FileManager.default.createDirectory(at: libraryRoot.appendingPathComponent(dir), withIntermediateDirectories: true)
    }

    let lib = Library(builtAt: Date(), spotifyUser: export.user, tracks: tracks, playlists: playlists)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    try enc.encode(lib).write(to: libraryRoot.appendingPathComponent("library.json"))

    var csv = "artist,title,album,year,duration,isrc,playlist_count,playlists,first_added,status\n"
    for t in tracks.sorted(by: { ($0.artists.first ?? "").localizedCaseInsensitiveCompare($1.artists.first ?? "") == .orderedAscending }) {
        let dur = t.durationMs.map { String(format: "%d:%02d", $0 / 60000, $0 / 1000 % 60) }
        let row: [String?] = [t.artists.joined(separator: ", "), t.title, t.album, t.year, dur, t.isrc,
                              String(t.playlists.count), t.playlists.joined(separator: " | "), t.firstAdded.map { String($0.prefix(10)) }, t.status]
        csv += row.map(csvField).joined(separator: ",") + "\n"
    }
    try csv.write(to: libraryRoot.appendingPathComponent("library.csv"), atomically: true, encoding: .utf8)

    // Summary
    let totalMin = tracks.compactMap(\.durationMs).reduce(0, +) / 60000
    print("Library: \(tracks.count) unique tracks (~\(totalMin / 60)h \(totalMin % 60)m) from \(playlists.count) sources")
    if skippedLocal > 0 { print("  (\(skippedLocal) local/unavailable Spotify entries ignored)") }
    print("\nPlaylists:")
    for p in playlists.sorted(by: { $0.trackIDs.count > $1.trackIDs.count }) {
        print("  \(String(p.trackIDs.count).padding(toLength: 5, withPad: " ", startingAt: 0)) \(p.name)\(p.collaborative ? " (collab)" : "")")
    }
    let multi = tracks.filter { $0.playlists.count > 1 }.count
    print("\nIn 2+ playlists: \(multi)    Only in Liked Songs: \(tracks.filter { $0.playlists == ["Liked Songs"] }.count)")
    var artistCounts: [String: Int] = [:]
    tracks.forEach { $0.artists.forEach { artistCounts[$0, default: 0] += 1 } }
    print("Top artists: " + artistCounts.sorted { $0.value > $1.value }.prefix(12).map { "\($0.key) (\($0.value))" }.joined(separator: ", "))
    var decades: [String: Int] = [:]
    tracks.compactMap(\.year).compactMap(Int.init).forEach { decades["\($0 / 10 * 10)s", default: 0] += 1 }
    print("By decade: " + decades.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    print("\nWrote \(libraryRoot.path)/library.csv and library.json")
}

func safeFileName(_ s: String) -> String {
    let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
    let cleaned = s.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
    return String(cleaned.prefix(180))
}
