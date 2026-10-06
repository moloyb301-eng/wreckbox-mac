import Foundation

// Genre per library track, cross-checked from several sources and mapped onto one DJ-friendly list.
// Spotify no longer exposes artist genres to new apps, so sources are: Deezer release genre (by ISRC),
// genre tags in local files, genre-named playlists you curated, and the artist's other tracks.

struct GenreInfo: Codable {
    var genre: String?
    var confidence: String              // "verified" (2+ sources agree), "likely" (1 source), "guess" (artist only), "unknown"
    var sources: [String: [String]]     // source → raw genre strings, for checking
}

enum GenreTool {
    static let cacheFile = libraryRoot.appendingPathComponent("_cache/genres.json")
    static let deezerCacheFile = libraryRoot.appendingPathComponent("_cache/deezer_genres.json")
    static let electronic = "Electronic"

    /// DJ genre families — also the folder names inside Tracks/ (no "/" in them). Based on Beatport's genre list
    /// (house / techno / bass / mainstage …, plus its open-format Hip-Hop, R&B, Pop, Latin, African) and split
    /// the way this library needs it (desi hip-hop, Bollywood, Punjabi, desi indie). Order matters: first match
    /// wins, so specific names come before general ones.
    static let rules: [(keys: [String], genre: String)] = [
        (["afro house", "afro-house", "afro tech", "afro melodic", "3step"], "Afro House"),
        (["amapiano", "gqom"], "Amapiano"),
        (["desi hip hop", "desi hip-hop", "desi rap", "hindi rap", "hindi hip hop", "indian hip hop", "indian hip-hop", "pakistani hip hop",
          "urdu rap", "urdu hip hop", "gully rap", "dhh"], "Desi Hip-Hop"),
        (["punjabi", "bhangra"], "Punjabi"),
        (["indian indie", "hindi indie", "urdu indie", "pakistani indie", "desi indie", "indie hindi", "indian singer-songwriter", "pakistani pop", "coke studio"], "Desi Indie"),
        (["bollywood", "filmi", "hindi", "indian music", "indian pop", "desi", "indian", "sufi", "ghazal", "qawwali", "tollywood", "kollywood", "tamil", "telugu", "bengali", "marathi"], "Bollywood"),
        (["drum & bass", "drum and bass", "drum n bass", "dnb", "jungle", "liquid funk"], "Drum & Bass"),
        (["uk garage", "ukg", "garage", "bassline", "2-step", "2step", "speed garage"], "UK Garage"),
        (["techno/house"], "House"),   // Deezer's combined label: mostly house
        (["big room", "progressive house", "electro house", "mainstage", "complextro", "edm"], "Mainstage & EDM"),
        (["techno"], "Techno"),
        (["tech house", "deep house", "melodic house", "organic house", "afro deep", "nu disco", "disco house", "jackin", "soulful house", "minimal",
          "house"], "House"),
        (["dubstep", "riddim", "bass music", "trap & bass", "future bass", "brostep", "midtempo", "bass"], "Bass"),
        (["festival", "trance", "hardstyle", "dance pop", "dance-pop"], "Mainstage & EDM"),
        (["baile", "funk carioca", "brazilian bass", "brazilian funk", "brazilian music", "funk brasileiro", "phonk"], "Brazilian Funk"),
        (["reggaeton", "latin", "dembow", "urbano", "cumbia", "salsa", "bachata"], "Latin"),
        (["afrobeats", "afrobeat", "african music", "afropop", "afro pop", "afro"], "Afrobeats"),
        (["k-pop", "kpop", "korean", "asian music", "j-pop"], "K-Pop"),
        (["rap", "hip hop", "hip-hop", "trap", "grime", "drill"], "Hip-Hop & Rap"),
        (["r&b", "rnb", "soul", "funk", "neo soul"], "R&B & Soul"),
        (["lo-fi", "lofi", "chill", "downtempo", "ambient", "chillout", "chillwave"], "Chill & Downtempo"),
        (["electronic", "electronica", "electro", "dance", "idm"], electronic),
        (["indie", "alternative", "singer & songwriter", "singer-songwriter", "folk", "bedroom pop"], "Indie & Alternative"),
        (["rock", "metal", "punk"], "Rock"),
        (["reggae", "dancehall"], "Reggae & Dancehall"),
        (["soundtrack", "films/games", "film scores", "score"], "Soundtrack"),
        (["jazz", "blues"], "Jazz & Blues"),
        (["classical"], "Classical"),
        (["pop"], "Pop"),
    ]
    static let electronicChildren: Set<String> = ["Afro House", "Amapiano", "House", "Techno", "Drum & Bass", "UK Garage", "Bass",
                                                   "Mainstage & EDM", "Brazilian Funk", "Chill & Downtempo"]
    /// Families that refine Bollywood / Indian (a Deezer "Bollywood / Indian" vote also supports them).
    static let desiChildren: Set<String> = ["Desi Hip-Hop", "Punjabi", "Desi Indie"]
    /// A general vote also backs the more specific family another source names (Deezer "Rap/Hip Hop" + Last.fm
    /// "desi hip hop" → Desi Hip-Hop), instead of the two competing.
    static let refinements: [String: Set<String>] = [
        electronic: electronicChildren,
        "Bollywood": desiChildren,
        "Hip-Hop & Rap": ["Desi Hip-Hop", "Brazilian Funk"],
        "House": ["Afro House", "Amapiano", "UK Garage"],
        "Afrobeats": ["Afro House", "Amapiano"],
        "Indie & Alternative": ["Desi Indie"],
        "Pop": ["Bollywood", "Desi Indie", "Punjabi", "K-Pop", "Latin", "Afrobeats", "Mainstage & EDM"],
    ]
    static var specific: Set<String> { electronicChildren.union(desiChildren).union(["Bollywood"]) }
    static var allGenres: [String] { var seen = Set<String>(); return rules.map(\.genre).filter { seen.insert($0).inserted } }

    static func djGenre(_ raw: String) -> String? {
        let s = " " + raw.lowercased() + " "
        return rules.first { r in r.keys.contains { s.contains($0) } }?.genre
    }

    /// Genres a playlist name clearly points to ("afro house" → Afro House). Mood names ("vibes.") give none.
    static func playlistGenre(_ name: String) -> String? {
        let n = " \(name.lowercased()) "
        let matched = rules.flatMap { r in r.keys.filter { n.contains($0) }.map { (key: $0, genre: r.genre) } }
        // "afro house" also contains "house" and "afro"; keep only the longest matching names.
        let kept = matched.filter { m in !matched.contains { $0.key != m.key && $0.key.contains(m.key) } }
        let hits = Set(kept.map(\.genre))
        guard hits.count == 1, let g = hits.first, g != "Chill / Lo-fi" else { return nil }   // "chill" playlists are moods
        return g
    }

    static func load() -> [String: GenreInfo] {
        (try? JSONDecoder().decode([String: GenreInfo].self, from: Data(contentsOf: cacheFile))) ?? [:]
    }

    // MARK: Build

    static func run(args: [String]) async throws {
        if let i = args.firstIndex(of: "--lastfm-key"), i + 1 < args.count { LastFM.apiKey = args[i + 1] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let lib = try dec.decode(Library.self, from: Data(contentsOf: libraryRoot.appendingPathComponent("library.json")))
        let analysis = Analyzer.loadCache()

        // 1. Deezer release genres (cached; ~2 requests per track).
        var deezer = (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: deezerCacheFile))) ?? [:]
        let todo = lib.tracks.filter { deezer[$0.id] == nil }
        log("Deezer genres: \(lib.tracks.count - todo.count) cached, \(todo.count) to look up")
        var albumGenres: [Int: [String]] = [:]
        var done = 0
        for chunk in stride(from: 0, to: todo.count, by: 4).map({ Array(todo[$0..<min($0 + 4, todo.count)]) }) {
            let results = await withTaskGroup(of: (String, Int?).self) { g -> [(String, Int?)] in
                for t in chunk { g.addTask { (t.id, await deezerAlbumID(t)) } }
                return await g.reduce(into: []) { $0.append($1) }
            }
            for (id, album) in results {
                guard let album else { deezer[id] = []; continue }
                if albumGenres[album] == nil {
                    let a = (try? await BPMTool.deezer("album/\(album)")) ?? [:]
                    albumGenres[album] = ((a["genres"] as? [String: Any])?["data"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                }
                deezer[id] = albumGenres[album]
            }
            done += chunk.count
            if done % 100 < 4 || done == todo.count {
                log("  \(done)/\(todo.count)")
                try JSONEncoder().encode(deezer).write(to: deezerCacheFile)
            }
        }
        try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(deezer).write(to: deezerCacheFile)

        // 1b. Last.fm listener tags (track, else artist) — detailed sub-genres incl. desi / electronic.
        let lastfm = await LastFM.tags(for: lib.tracks)
        _ = analysis

        // 2. Gather raw votes per track. (The genre inside the files isn't used: WreckBox writes it itself.)
        var raw: [String: [String: [String]]] = [:]
        for t in lib.tracks {
            var s: [String: [String]] = [:]
            if let d = deezer[t.id], !d.isEmpty { s["deezer"] = d }
            if let l = lastfm[t.id], !l.isEmpty { s["lastfm"] = l }
            let pls = t.playlists.filter { playlistGenre($0) != nil }
            if !pls.isEmpty { s["playlist"] = pls }
            raw[t.id] = s
        }

        // 3. Decide per track, then use artist consensus to fill gaps and as an extra vote.
        var result: [String: GenreInfo] = [:]
        for t in lib.tracks { result[t.id] = decide(raw[t.id] ?? [:], artistVote: nil) }
        var byArtist: [String: [String: Int]] = [:]
        for t in lib.tracks {
            guard let a = t.artists.first, let g = result[t.id]?.genre, result[t.id]?.confidence != "unknown" else { continue }
            byArtist[a, default: [:]][g, default: 0] += 1
        }
        for t in lib.tracks {
            let vote = t.artists.first.flatMap { byArtist[$0]?.max { $0.value < $1.value } }.map { $0.key }
            var s = raw[t.id] ?? [:]
            if let v = vote { s["artist"] = [v] }
            result[t.id] = decide(s, artistVote: vote)
        }

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(result).write(to: cacheFile)

        // Summary
        var counts: [String: Int] = [:]
        result.values.forEach { counts[$0.genre ?? "Unknown", default: 0] += 1 }
        let conf = Dictionary(grouping: result.values, by: \.confidence).mapValues(\.count)
        print("\nGenres for \(result.count) tracks — " + ["verified", "likely", "guess", "unknown"].map { "\($0): \(conf[$0] ?? 0)" }.joined(separator: ", "))
        for (g, n) in counts.sorted(by: { $0.value > $1.value }) { print("  \(String(n).padding(toLength: 5, withPad: " ", startingAt: 0)) \(g)") }
        print("Wrote \(cacheFile.path)")
    }

    /// Votes: each source's mapped genre counts once. A general "Dance / Electronic" vote also supports any
    /// electronic sub-genre another source names, so "Dance" + playlist "afro house" → Afro House, verified.
    static func decide(_ sources: [String: [String]], artistVote: String?) -> GenreInfo {
        var support: [String: Set<String>] = [:]
        for (src, vals) in sources where src != "artist" {
            let mapped = vals.compactMap(djGenre)
            // Last.fm tags come most-used first: take the most specific of the top few, not all of them.
            let picked = src == "lastfm" ? (lastfmGenre(vals).map { [$0] } ?? [])
                                          : Array(Set(mapped))
            for g in picked { support[g, default: []].insert(src) }
        }
        for (parent, children) in refinements {
            guard let generic = support[parent] else { continue }
            for g in support.keys where children.contains(g) { support[g]!.formUnion(generic) }
        }
        if let a = artistVote, support[a] != nil { support[a]!.insert("artist") }
        if let a = artistVote, let children = refinements[a] {
            for g in support.keys where children.contains(g) { support[g]!.insert("artist") }
        }
        let priority = ["lastfm": 4, "playlist": 3, "deezer": 2, "artist": 1]
        let best = support.max { a, b in
            if a.value.count != b.value.count { return a.value.count < b.value.count }
            let sa = specific.contains(a.key) ? 1 : 0, sb = specific.contains(b.key) ? 1 : 0
            if sa != sb { return sa < sb }
            return (a.value.map { priority[$0] ?? 0 }.max() ?? 0) < (b.value.map { priority[$0] ?? 0 }.max() ?? 0)
        }
        if let (g, srcs) = best {
            return GenreInfo(genre: g, confidence: srcs.count >= 2 ? "verified" : "likely", sources: sources)
        }
        if let a = artistVote { return GenreInfo(genre: a, confidence: "guess", sources: sources) }
        return GenreInfo(genre: nil, confidence: "unknown", sources: sources)
    }

    /// One family from a track's Last.fm tags (most-used first). Tags combine: "Indian" + "indie pop" is Desi
    /// Indie, "Pakistani" + "rap" is Desi Hip-Hop — on their own they'd read as Bollywood / Hip-Hop.
    static func lastfmGenre(_ tags: [String]) -> String? {
        let top = tags.prefix(6).map { " \($0.lowercased()) " }
        let has: ([String]) -> Bool = { keys in top.contains { t in keys.contains { t.contains($0) } } }
        if has(["indian", "india", "pakistani", "pakistan", "hindi", "urdu", "desi", "bollywood"]) {
            if has(["rap", "hip hop", "hip-hop", "trap", "drill"]) { return "Desi Hip-Hop" }
            if has(["punjabi", "bhangra"]) { return "Punjabi" }
            if has(["indie", "acoustic", "singer-songwriter", "singer songwriter", "folk", "alternative", "lo-fi", "lofi", "bedroom"]) { return "Desi Indie" }
        }
        let mapped = tags.compactMap(djGenre)
        return mapped.prefix(4).first { specific.contains($0) } ?? mapped.first
    }

    static func deezerAlbumID(_ t: LibraryTrack) async -> Int? {
        if let isrc = t.isrc, let tr = try? await BPMTool.deezer("track/isrc:\(isrc)"),
           let id = (tr["album"] as? [String: Any])?["id"] as? Int { return id }
        let q = "artist:\"\(t.artists.first ?? "")\" track:\"\(t.title)\""
        guard let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let hit = ((try? await BPMTool.deezer("search?q=" + enc))?["data"] as? [[String: Any]])?.first else { return nil }
        return (hit["album"] as? [String: Any])?["id"] as? Int
    }

    static func readGenreTag(_ path: String) throws -> String? {
        // Inventory's tag reader is async; a tiny synchronous wrapper keeps this file simple.
        let sem = DispatchSemaphore(value: 0)
        var g: String?
        Task.detached { g = await readTrack(URL(fileURLWithPath: path)).genre; sem.signal() }
        sem.wait()
        return g
    }

    static func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
}
