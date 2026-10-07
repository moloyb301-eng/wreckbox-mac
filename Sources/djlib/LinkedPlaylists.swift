import Foundation
import SwiftUI

// Playlists added from a link: a Spotify playlist (any public one, read with your Spotify login), or a YouTube /
// YouTube Music playlist (public ones need no login; "Import my YouTube Music" reads your own playlists and
// Liked songs with your browser login). They're kept in linked-playlists.json — with the tracks as last read —
// and merged into the library on every rebuild, so the morning Spotify sync never drops them; the morning sync
// refreshes them too. Their missing tracks go through the usual Soulseek → YouTube → FLAC-upgrade order.

struct LinkedPlaylist: Codable {
    var kind: String          // "spotify" | "youtube"
    var id: String
    var name: String
    var url: String
    var addedAt: String
    var refreshedAt: String?
    var tracks: [SpotifyTrack]
}

enum LinkedPlaylists {
    static var file: URL { libraryRoot.appendingPathComponent("linked-playlists.json") }

    static func load() -> [LinkedPlaylist] {
        (try? JSONDecoder().decode([LinkedPlaylist].self, from: Data(contentsOf: file))) ?? []
    }

    static func save(_ all: [LinkedPlaylist]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(all).write(to: file, options: .atomic)
    }

    /// What a pasted link points at: ("spotify", id) or ("youtube", list id).
    static func parse(_ link: String) -> (kind: String, id: String)? {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = s.range(of: #"(?:open\.spotify\.com/(?:intl-[a-z]+/)?playlist/|spotify:playlist:)([A-Za-z0-9]{10,})"#, options: .regularExpression) {
            let id = s[m].split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
            return ("spotify", String(id.prefix { $0.isLetter || $0.isNumber }))
        }
        if (s.contains("youtube.com") || s.contains("youtu.be")), let m = s.range(of: #"list=[A-Za-z0-9_-]+"#, options: .regularExpression) {
            return ("youtube", String(s[m].dropFirst(5)))
        }
        return nil
    }

    // MARK: reading

    static func fetchSpotify(_ id: String) async throws -> (name: String, tracks: [SpotifyTrack]) {
        let api = SpotifyImport.API(token: try await SpotifyImport.accessToken())
        let meta = try await api.get("playlists/\(id)?fields=name")
        let items: [[String: Any]]
        do { items = try await api.pages("playlists/\(id)/items?limit=50") }
        catch SpotifyError.http(404, _) { items = try await api.pages("playlists/\(id)/tracks?limit=50") }
        return (meta["name"] as? String ?? "Spotify playlist", items.compactMap(SpotifyImport.parseItem))
    }

    /// yt-fill's `playlist-json` / `library-json` → playlists of tracks (the video id rides along in spotifyID's
    /// place as "yt:<id>", so YouTube fill can take that exact upload later).
    static func ytfill(_ args: [String]) async throws -> Any {
        let data = await Task.detached(priority: .userInitiated) { () -> Data in
            let p = Process()
            p.executableURL = AppPaths.ytFill
            p.arguments = args
            p.environment = AppPaths.toolEnvironment
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return Data() }
            let d = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return d
        }.value
        let last = data.split(separator: UInt8(ascii: "\n")).last.map { Data($0) } ?? Data()
        let j = try JSONSerialization.jsonObject(with: last)
        if let e = (j as? [String: Any])?["error"] as? String { throw NSError(domain: "WreckBox", code: 1, userInfo: [NSLocalizedDescriptionKey: e]) }
        return j
    }

    static func ytTracks(_ pl: [String: Any]) -> [SpotifyTrack] {
        (pl["tracks"] as? [[String: Any]] ?? []).map { t in
            SpotifyTrack(spotifyID: nil, name: t["title"] as? String ?? "", artists: t["artists"] as? [String] ?? [],
                         album: t["album"] as? String, releaseDate: nil, isrc: nil,
                         durationMs: (t["seconds"] as? Int).map { $0 * 1000 }, explicit: nil, isLocal: false,
                         addedAt: ISO8601DateFormatter().string(from: Date()), artworkURL: t["thumbnail"] as? String)
        }
    }

    static func fetchYouTube(_ id: String) async throws -> (name: String, tracks: [SpotifyTrack]) {
        let j = try await ytfill(["playlist-json", id]) as? [String: Any] ?? [:]
        return (j["name"] as? String ?? "YouTube playlist", ytTracks(j))
    }

    /// Adds (or refreshes) one link. Returns the playlist's name and track count.
    static func add(_ link: String) async throws -> (String, Int) {
        guard let (kind, id) = parse(link) else {
            throw NSError(domain: "WreckBox", code: 2, userInfo: [NSLocalizedDescriptionKey: "That isn't a Spotify, YouTube or YouTube Music playlist link."])
        }
        let got: (name: String, tracks: [SpotifyTrack])
        do {
            got = kind == "spotify" ? try await fetchSpotify(id) : try await fetchYouTube(id)
        } catch SpotifyError.http(404, _) {
            throw NSError(domain: "WreckBox", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "Spotify doesn't let apps read its own playlists (Today's Top Hits, \"This Is…\", radios). Copy the songs into a playlist of yours and add that, or use the YouTube Music version."])
        } catch SpotifyError.missingClientID {
            throw NSError(domain: "WreckBox", code: 4, userInfo: [NSLocalizedDescriptionKey: "Connect Spotify first (Sync my Spotify) — WreckBox reads Spotify links with your login."])
        }
        var all = load()
        let now = ISO8601DateFormatter().string(from: Date())
        if let i = all.firstIndex(where: { $0.kind == kind && $0.id == id }) {
            all[i].tracks = got.tracks; all[i].name = got.name; all[i].refreshedAt = now
        } else {
            all.append(LinkedPlaylist(kind: kind, id: id, name: got.name, url: link, addedAt: now, refreshedAt: now, tracks: got.tracks))
        }
        save(all)
        return (got.name, got.tracks.count)
    }

    /// Your YouTube Music library: every playlist of yours + Liked songs, each kept as a linked playlist.
    static func importYouTubeLibrary() async throws -> Int {
        let lists = try await ytfill(["library-json"]) as? [[String: Any]] ?? []
        var all = load()
        let now = ISO8601DateFormatter().string(from: Date())
        var n = 0
        for pl in lists {
            let tracks = ytTracks(pl)
            guard let id = pl["id"] as? String, !tracks.isEmpty else { continue }
            let name = pl["name"] as? String ?? "YouTube playlist"
            if let i = all.firstIndex(where: { $0.kind == "youtube" && $0.id == id }) {
                all[i].tracks = tracks; all[i].name = name; all[i].refreshedAt = now
            } else {
                all.append(LinkedPlaylist(kind: "youtube", id: id, name: name, url: "https://music.youtube.com/playlist?list=\(id)", addedAt: now, refreshedAt: now, tracks: tracks))
            }
            n += 1
        }
        save(all)
        return n
    }

    /// The morning sync: read every linked playlist again (ones that fail keep their last tracks).
    static func refreshAll() async {
        var all = load()
        let now = ISO8601DateFormatter().string(from: Date())
        for i in all.indices {
            let got = try? await (all[i].kind == "spotify" ? fetchSpotify(all[i].id) : fetchYouTube(all[i].id))
            if let got { all[i].tracks = got.tracks; all[i].name = got.name; all[i].refreshedAt = now }
        }
        save(all)
    }

    static func remove(kind: String, id: String) {
        save(load().filter { !($0.kind == kind && $0.id == id) })
    }
}

extension LibraryStore {
    /// After a link is added or removed: rebuild the library (merging it in) and look for its new tracks.
    func rebuildWithLinks() async {
        do {
            try await Task.detached(priority: .userInitiated) { try buildLibrary() }.value
            reloadLibrary()
            // New tracks to fetch: start Soulseek (after the VPN reminder) if it's set up and not running.
            if soulseek.configured && !soulseek.running { DownloadGate.then { self.startSoulseek() } }
        } catch {
            log("playlists", nil, "couldn't rebuild the library: \(error.localizedDescription)")
        }
    }
}

// MARK: - "Add playlist" sheet

struct AddPlaylistSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var working = false
    @State private var message: String?
    @State private var linked = LinkedPlaylists.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a playlist").font(Theme.ui(20, .semibold)).foregroundStyle(Theme.text)
            Text("Paste a Spotify, YouTube or YouTube Music playlist link. Its tracks join your library and download in the best quality available — Soulseek first, then YouTube.")
                .font(Theme.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("https://open.spotify.com/playlist/…  or  https://music.youtube.com/playlist?list=…", text: $link)
                    .textFieldStyle(.plain).font(Theme.ui(13))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.glassFill).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline)))
                    .onSubmit { add() }
                PillButton(label: working ? "Adding…" : "Add", icon: "plus", style: .smart) { add() }.disabled(working || link.isEmpty)
            }
            HStack(spacing: 8) {
                PillButton(label: "Import my YouTube Music", icon: "play.rectangle") { importYT() }.disabled(working)
                    .help("Your YouTube Music playlists and Liked songs, read with your browser's YouTube login")
                PillButton(label: "Sync my Spotify", icon: "arrow.triangle.2.circlepath") { Task { await store.syncPlaylists() } }.disabled(working)
                    .help("Your own Spotify playlists and Liked Songs")
            }
            if let m = message { Text(m).font(Theme.ui(12.5)).foregroundStyle(m.hasPrefix("Added") || m.hasPrefix("Imported") ? Theme.lilac : Theme.peach) }
            if !linked.isEmpty {
                DotLabel("Added from links", color: Theme.text)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(linked, id: \.id) { pl in
                            HStack(spacing: 10) {
                                Image(systemName: pl.kind == "spotify" ? "music.note.list" : "play.rectangle").foregroundStyle(Theme.text3).frame(width: 18)
                                Text(pl.name).font(Theme.ui(13, .semibold)).lineLimit(1)
                                Text("\(pl.tracks.count) tracks").font(Theme.ui(12)).foregroundStyle(Theme.text3)
                                Spacer()
                                Button { remove(pl) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                                    .buttonStyle(.plain).foregroundStyle(Theme.text3).help("Remove this playlist")
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.glassFill))
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            HStack { Spacer(); PillButton(label: "Done", style: .primary) { dismiss() } }
        }
        .padding(22)
        .frame(width: 560)
        .background(Theme.bgRaised)
        .preferredColorScheme(.dark)
    }

    private func add() {
        let l = link
        working = true
        message = nil
        Task {
            do {
                let (name, n) = try await LinkedPlaylists.add(l)
                await store.rebuildWithLinks()
                message = "Added \(name) — \(n) tracks."
                link = ""
            } catch {
                message = error.localizedDescription
            }
            linked = LinkedPlaylists.load()
            working = false
        }
    }

    private func importYT() {
        working = true
        message = nil
        Task {
            do {
                let n = try await LinkedPlaylists.importYouTubeLibrary()
                await store.rebuildWithLinks()
                message = "Imported \(n) YouTube Music playlists."
            } catch {
                message = error.localizedDescription
            }
            linked = LinkedPlaylists.load()
            working = false
        }
    }

    private func remove(_ pl: LinkedPlaylist) {
        LinkedPlaylists.remove(kind: pl.kind, id: pl.id)
        linked = LinkedPlaylists.load()
        Task { await store.rebuildWithLinks() }
    }
}
