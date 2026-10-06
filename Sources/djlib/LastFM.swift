import Foundation

// Last.fm listener tags: detailed genres ("desi hip hop", "afro house", "punjabi") for the genre families.
// Free API key from last.fm/api, saved in _cache/lastfm.json. Track tags first, the artist's tags when a track
// has none. Cached per track and per artist, so later runs only look up new tracks.

enum LastFM {
    static var keyFile: URL { libraryRoot.appendingPathComponent("_cache/lastfm.json") }
    static var trackCache: URL { libraryRoot.appendingPathComponent("_cache/lastfm_tags.json") }
    static var artistCache: URL { libraryRoot.appendingPathComponent("_cache/lastfm_artist_tags.json") }

    static var apiKey: String? {
        get { ((try? JSONSerialization.jsonObject(with: Data(contentsOf: keyFile))) as? [String: String])?["apiKey"] }
        set {
            try? FileManager.default.createDirectory(at: keyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: ["apiKey": newValue ?? ""]).write(to: keyFile, options: .atomic)
        }
    }

    /// Tags not worth anything for genre (personal / chart / descriptive).
    private static let junk: Set<String> = ["seen live", "favorites", "favourite", "favorite", "love", "awesome", "beautiful", "male vocalists",
                                            "female vocalists", "spotify", "my top songs", "under 2000 listeners", "all", "music"]

    /// Track id → tags, most-used first. Without an API key: whatever is cached (usually nothing).
    static func tags(for tracks: [LibraryTrack]) async -> [String: [String]] {
        var byTrack = (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: trackCache))) ?? [:]
        var byArtist = (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: artistCache))) ?? [:]
        guard let key = apiKey, !key.isEmpty else { return byTrack }
        let todo = tracks.filter { byTrack[$0.id] == nil }
        GenreTool.log("Last.fm tags: \(tracks.count - todo.count) cached, \(todo.count) to look up")
        var done = 0
        for chunk in stride(from: 0, to: todo.count, by: 4).map({ Array(todo[$0..<min($0 + 4, todo.count)]) }) {
            let found = await withTaskGroup(of: (String, [String]).self) { g -> [(String, [String])] in
                for t in chunk {
                    g.addTask { (t.id, await top("track.gettoptags", ["artist": t.artists.first ?? "", "track": t.title], key: key)) }
                }
                return await g.reduce(into: []) { $0.append($1) }
            }
            for (id, tags) in found { byTrack[id] = tags }
            // Tracks Last.fm has no tags for get their artist's tags.
            for t in chunk where byTrack[t.id]?.isEmpty != false {
                guard let a = t.artists.first else { continue }
                if byArtist[a] == nil { byArtist[a] = await top("artist.gettoptags", ["artist": a], key: key) }
                byTrack[t.id] = byArtist[a] ?? []
            }
            done += chunk.count
            if done % 100 < 4 || done == todo.count {
                GenreTool.log("  \(done)/\(todo.count)")
                try? JSONEncoder().encode(byTrack).write(to: trackCache)
                try? JSONEncoder().encode(byArtist).write(to: artistCache)
            }
            try? await Task.sleep(for: .milliseconds(250))   // Last.fm asks for ≤ 5 requests a second
        }
        return byTrack
    }

    private static func top(_ method: String, _ params: [String: String], key: String) async -> [String] {
        var c = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        c.queryItems = [URLQueryItem(name: "method", value: method), URLQueryItem(name: "api_key", value: key),
                        URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "autocorrect", value: "1")]
            + params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tags = (j["toptags"] as? [String: Any])?["tag"] as? [[String: Any]] else { return [] }
        return tags.filter { ($0["count"] as? Int ?? 0) >= 10 }
            .compactMap { ($0["name"] as? String)?.lowercased() }
            .filter { !junk.contains($0) }
            .prefix(8).map { $0 }
    }
}
