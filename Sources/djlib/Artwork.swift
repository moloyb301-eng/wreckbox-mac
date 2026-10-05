import AppKit
import AVFoundation
import Foundation

// Album art for library tracks, cached on disk in _cache/artwork/<track>.jpg.
// Sources, in order: the Spotify cover URL from the import, art embedded in the local file,
// Deezer (by the track's Deezer ID from the BPM cache, else search), then the iTunes Search API.
// Tracks with no art anywhere get a <track>.none marker so they aren't looked up again.

actor ArtworkLoader {
    static let shared = ArtworkLoader()
    static let dir = libraryRoot.appendingPathComponent("_cache/artwork")

    private let memory = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private var networkSlots = 4
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        memory.countLimit = 600
    }

    static func fileStem(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    func image(for track: LibraryTrack, localPath: String?, deezerID: Int?) async -> NSImage? {
        let key = track.id as NSString
        if let img = memory.object(forKey: key) { return img }
        if let t = inFlight[track.id] { return await t.value }
        let task = Task { await self.load(track, localPath: localPath, deezerID: deezerID) }
        inFlight[track.id] = task
        let img = await task.value
        inFlight[track.id] = nil
        if let img { memory.setObject(img, forKey: key) }
        return img
    }

    private func load(_ t: LibraryTrack, localPath: String?, deezerID: Int?) async -> NSImage? {
        let stem = Self.fileStem(t.id)
        let file = Self.dir.appendingPathComponent(stem + ".jpg")
        let none = Self.dir.appendingPathComponent(stem + ".none")
        if let img = NSImage(contentsOf: file) { return img }
        if let localPath, let data = await Self.embeddedArt(localPath), let img = NSImage(data: data) {
            try? data.write(to: file)
            return img
        }
        if FileManager.default.fileExists(atPath: none.path) { return nil }

        await acquire()
        defer { release() }
        var urls: [URL] = []
        if let s = t.artworkURL, let u = URL(string: s) { urls.append(u) }
        if let u = await Self.deezerCover(t, deezerID: deezerID) { urls.append(u) }
        for u in urls {
            if let (data, resp) = try? await URLSession.shared.data(from: u),
               (resp as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: data) {
                try? data.write(to: file)
                return img
            }
        }
        if let u = await Self.itunesCover(t), let (data, _) = try? await URLSession.shared.data(from: u), let img = NSImage(data: data) {
            try? data.write(to: file)
            return img
        }
        FileManager.default.createFile(atPath: none.path, contents: nil)
        return nil
    }

    private func acquire() async {
        if networkSlots > 0 { networkSlots -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { networkSlots += 1 } else { waiters.removeFirst().resume() }
    }

    // MARK: Sources

    static func embeddedArt(_ path: String) async -> Data? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let d = try? await item.load(.dataValue) { return d }
        }
        return nil
    }

    static func deezerCover(_ t: LibraryTrack, deezerID: Int?) async -> URL? {
        var json: [String: Any]?
        if let id = deezerID, let u = URL(string: "https://api.deezer.com/track/\(id)") {
            json = await getJSON(u)
        } else {
            let artist = t.artists.first ?? ""
            let q = "artist:\"\(artist)\" track:\"\(t.title)\""
            var c = URLComponents(string: "https://api.deezer.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "limit", value: "1")]
            json = (await getJSON(c.url!)).flatMap { ($0["data"] as? [[String: Any]])?.first }
        }
        let album = json?["album"] as? [String: Any]
        return (album?["cover_big"] as? String ?? album?["cover_medium"] as? String).flatMap(URL.init(string:))
    }

    static func itunesCover(_ t: LibraryTrack) async -> URL? {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [URLQueryItem(name: "term", value: "\(t.artists.first ?? "") \(t.title)"),
                        URLQueryItem(name: "entity", value: "song"), URLQueryItem(name: "limit", value: "1")]
        guard let r = (await getJSON(c.url!))?["results"] as? [[String: Any]],
              let s = r.first?["artworkUrl100"] as? String else { return nil }
        return URL(string: s.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
    }

    static func getJSON(_ u: URL) async -> [String: Any]? {
        guard let (data, resp) = try? await URLSession.shared.data(from: u), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
