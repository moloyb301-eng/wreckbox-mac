import Foundation

// "Request a track" from the phone: the Mac hunts for it on Soulseek right away, and the phone is told (over the
// live events stream) when it's ready. Tracks that aren't in any Spotify playlist are added to a "Phone requests"
// playlist; they're kept in requests.json so rebuilding the library from Spotify doesn't drop them.

struct PhoneRequestedTrack: Codable {
    var artist: String
    var title: String
    var at: String
}

enum PhoneRequests {
    static let playlist = "Phone requests"
    static var file: URL { libraryRoot.appendingPathComponent("requests.json") }

    static func load() -> [PhoneRequestedTrack] {
        (try? JSONDecoder().decode([PhoneRequestedTrack].self, from: Data(contentsOf: file))) ?? []
    }

    static func id(artist: String, title: String) -> String {
        "req:" + normalized(artist) + "|" + normalized(title)
    }

    static func track(_ r: PhoneRequestedTrack) -> LibraryTrack {
        LibraryTrack(id: id(artist: r.artist, title: r.title), artists: [r.artist], title: r.title, album: nil, year: nil,
                     isrc: nil, spotifyIDs: [], durationMs: nil, playlists: [playlist], firstAdded: r.at,
                     fileName: safeFileName("\(r.artist) - \(r.title)"), localPath: nil, status: "missing", artworkURL: nil)
    }

    /// Adds the requested tracks (and their playlist) to a freshly built library.
    static func merge(into tracks: inout [LibraryTrack], playlists: inout [LibraryPlaylist]) {
        let reqs = load()
        guard !reqs.isEmpty else { return }
        var ids: [String] = []
        let have = Set(tracks.map(\.id))
        for r in reqs {
            let t = track(r)
            if !have.contains(t.id) { tracks.append(t) }
            if !ids.contains(t.id) { ids.append(t.id) }
        }
        playlists.removeAll { $0.name == playlist }
        playlists.append(LibraryPlaylist(name: playlist, spotifyID: nil, collaborative: false, trackIDs: ids))
    }
}

extension LibraryStore {
    /// Handles a request from the phone. Returns the library id, or nil if there's nothing to look for.
    @discardableResult
    func phoneRequest(id: String?, artist: String?, title: String?, query: String?) -> String? {
        var trackID = id.flatMap { track($0) == nil ? nil : $0 }
        if trackID == nil, let artist = artist?.trimmingCharacters(in: .whitespaces), let title = title?.trimmingCharacters(in: .whitespaces),
           !artist.isEmpty, !title.isEmpty {
            trackID = addRequestedTrack(artist: artist, title: title)
        }
        guard let tid = trackID else { return nil }
        if state.tracks[tid]?.status == .downloaded { return tid }
        retrySync([tid], query: query)
        startSoulseek()   // no-op when it's already running
        return tid
    }

    private func addRequestedTrack(artist: String, title: String) -> String {
        let r = PhoneRequestedTrack(artist: artist, title: title, at: ISO8601DateFormatter().string(from: Date()))
        let t = PhoneRequests.track(r)
        if track(t.id) != nil { return t.id }
        var reqs = PhoneRequests.load()
        reqs.append(r)
        if let d = try? JSONEncoder().encode(reqs) { try? d.write(to: PhoneRequests.file, options: .atomic) }
        guard var lib = library else { return t.id }
        lib.tracks.append(t)
        if let i = lib.playlists.firstIndex(where: { $0.name == PhoneRequests.playlist }) {
            lib.playlists[i].trackIDs.append(t.id)
        } else {
            lib.playlists.append(LibraryPlaylist(name: PhoneRequests.playlist, spotifyID: nil, collaborative: false, trackIDs: [t.id]))
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(lib).write(to: libraryRoot.appendingPathComponent("library.json"), options: .atomic)
        library = lib
        log("phone", t.id, "requested from the phone: \(artist) - \(title)")
        return t.id
    }

    /// Where a requested track stands, for the phone: ready / searching / not_found / failed.
    func requestStatus(_ id: String) -> String {
        if state.tracks[id]?.status == .downloaded { return "ready" }
        let rec = soulseek.records[id]
        let retryAt = soulseek.overrides[id]?["retryAt"] ?? ""
        if let rec, rec.lastTry >= retryAt, rec.status == "not_found" || rec.status == "failed" { return rec.status }
        return "searching"
    }
}
