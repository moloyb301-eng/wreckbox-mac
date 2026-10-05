import AppKit
import CryptoKit
import Foundation
import Network

// Imports playlist + Liked Songs metadata via the Spotify Web API (read-only scopes, PKCE login).

struct SpotifyTrack: Codable {
    var spotifyID: String?
    var name: String
    var artists: [String]
    var album: String?
    var releaseDate: String?
    var isrc: String?
    var durationMs: Int?
    var explicit: Bool?
    var isLocal: Bool
    var addedAt: String?
    var artworkURL: String?     // album cover, ~300 px
}

struct SpotifyPlaylist: Codable {
    var id: String
    var name: String
    var owner: String
    var ownedByMe: Bool
    var collaborative: Bool
    var description: String?
    var url: String?
    var tracks: [SpotifyTrack]
    var skippedReason: String?
}

struct SpotifyExport: Codable {
    var user: String
    var exportedAt: Date
    var likedSongs: [SpotifyTrack]
    var playlists: [SpotifyPlaylist]
}

enum SpotifyError: Error, CustomStringConvertible {
    case missingClientID, auth(String), http(Int, String)
    var description: String {
        switch self {
        case .missingClientID: return "no Spotify Client ID. Run: djlib spotify --client-id <ID>  (from developer.spotify.com/dashboard)"
        case .auth(let m): return "login failed: \(m)"
        case .http(let c, let m): return "Spotify API \(c): \(m)"
        }
    }
}

enum SpotifyImport {
    static let redirectURI = "http://127.0.0.1:8888/callback"
    static let scopes = "playlist-read-private playlist-read-collaborative user-library-read"
    static let configDir = home.appendingPathComponent("Library/Application Support/DJLibrary")
    static let configFile = configDir.appendingPathComponent("spotify.json")
    static let exportDir = home.appendingPathComponent("Music/DJ Library/_spotify")

    struct Config: Codable { var clientID: String; var refreshToken: String? }

    /// Fresh access token from the saved refresh token (rotates and saves the refresh token).
    static func accessToken() async throws -> String {
        guard var cfg = loadConfig(), let rt = cfg.refreshToken else { throw SpotifyError.missingClientID }
        let t = try await refresh(clientID: cfg.clientID, refreshToken: rt)
        cfg.refreshToken = t.refresh ?? rt
        try saveConfig(cfg)
        return t.access
    }

    /// Debug helper: `djlib spotify-get <api path>` prints the raw JSON.
    static func debugGet(_ path: String) async throws {
        let json = try await API(token: accessToken()).get(path)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    static func run(args: [String]) async throws {
        var config = loadConfig()
        if let i = args.firstIndex(of: "--client-id"), i + 1 < args.count {
            config = Config(clientID: args[i + 1], refreshToken: nil)
        }
        guard var cfg = config else { throw SpotifyError.missingClientID }
        let includeGenerated = args.contains("--include-generated")

        var token: String
        if let rt = cfg.refreshToken, let refreshed = try? await refresh(clientID: cfg.clientID, refreshToken: rt) {
            token = refreshed.access
            cfg.refreshToken = refreshed.refresh ?? rt
        } else {
            let t = try await login(clientID: cfg.clientID)
            token = t.access
            cfg.refreshToken = t.refresh
        }
        try saveConfig(cfg)

        let api = API(token: token)
        let me = try await api.get("me")
        let userID = me["id"] as? String ?? ""
        log("Signed in as \(me["display_name"] as? String ?? userID)")

        log("Fetching Liked Songs…")
        let liked = try await api.pages("me/tracks?limit=50").compactMap(parseItem)
        log("  \(liked.count) liked songs")

        log("Fetching playlists…")
        var playlists: [SpotifyPlaylist] = []
        for p in try await api.pages("me/playlists?limit=50") {
            guard let id = p["id"] as? String else { continue }
            let owner = p["owner"] as? [String: Any]
            let ownerID = owner?["id"] as? String ?? ""
            var pl = SpotifyPlaylist(
                id: id, name: p["name"] as? String ?? "(untitled)",
                owner: owner?["display_name"] as? String ?? ownerID,
                ownedByMe: ownerID == userID, collaborative: p["collaborative"] as? Bool ?? false,
                description: (p["description"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                url: (p["external_urls"] as? [String: Any])?["spotify"] as? String,
                tracks: [], skippedReason: nil)

            // Spotify-generated mixes (Daily Mix, Discover Weekly…) aren't readable by third-party apps anyway.
            if ownerID == "spotify" && !includeGenerated {
                pl.skippedReason = "Spotify-generated playlist"
                playlists.append(pl); continue
            }
            do {
                let items: [[String: Any]]
                do { items = try await api.pages("playlists/\(id)/items?limit=50") }
                catch SpotifyError.http(404, _) { items = try await api.pages("playlists/\(id)/tracks?limit=50") }
                pl.tracks = items.compactMap(parseItem)
            } catch {
                pl.skippedReason = "\(error)"
            }
            log("  \(pl.name): \(pl.skippedReason ?? "\(pl.tracks.count) tracks")")
            playlists.append(pl)
        }

        try write(SpotifyExport(user: userID, exportedAt: Date(), likedSongs: liked, playlists: playlists))
    }

    // MARK: Parsing

    static func parseItem(_ item: [String: Any]) -> SpotifyTrack? {
        guard let t = (item["track"] ?? item["item"]) as? [String: Any], (t["type"] as? String ?? "track") == "track" else { return nil }
        let album = t["album"] as? [String: Any]
        return SpotifyTrack(
            spotifyID: t["id"] as? String,
            name: t["name"] as? String ?? "",
            artists: (t["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? [],
            album: album?["name"] as? String,
            releaseDate: album?["release_date"] as? String,
            isrc: (t["external_ids"] as? [String: Any])?["isrc"] as? String,
            durationMs: t["duration_ms"] as? Int,
            explicit: t["explicit"] as? Bool,
            isLocal: t["is_local"] as? Bool ?? false,
            addedAt: item["added_at"] as? String,
            artworkURL: coverURL(album?["images"] as? [[String: Any]]))
    }

    /// The album image closest to 300 px wide (Spotify lists 640, 300 and 64).
    static func coverURL(_ images: [[String: Any]]?) -> String? {
        guard let images, !images.isEmpty else { return nil }
        let best = images.min { abs(($0["width"] as? Int ?? 640) - 300) < abs(($1["width"] as? Int ?? 640) - 300) }
        return best?["url"] as? String
    }

    // MARK: Output

    static func write(_ export: SpotifyExport) throws {
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(export).write(to: exportDir.appendingPathComponent("spotify.json"))

        var csv = "playlist,owned_by_me,position,artist,title,album,release_date,isrc,duration,added_at,spotify_id\n"
        let all = [("Liked Songs", true, export.likedSongs)] + export.playlists.map { ($0.name, $0.ownedByMe, $0.tracks) }
        for (name, mine, tracks) in all {
            for (i, t) in tracks.enumerated() {
                let dur = t.durationMs.map { String(format: "%d:%02d", $0 / 60000, $0 / 1000 % 60) }
                csv += [name, mine ? "yes" : "no", String(i + 1), t.artists.joined(separator: ", "), t.name, t.album,
                        t.releaseDate, t.isrc, dur, t.addedAt, t.spotifyID].map(csvField).joined(separator: ",") + "\n"
            }
        }
        try csv.write(to: exportDir.appendingPathComponent("spotify_tracks.csv"), atomically: true, encoding: .utf8)

        let read = export.playlists.filter { $0.skippedReason == nil }
        let allTracks = export.likedSongs + read.flatMap(\.tracks)
        let unique = Set(allTracks.map { $0.isrc ?? $0.spotifyID ?? "\($0.artists) \($0.name)" })
        print("\nPlaylists: \(export.playlists.count) (\(read.filter(\.ownedByMe).count) yours, \(read.filter { !$0.ownedByMe }.count) followed, \(export.playlists.count - read.count) skipped)")
        print("Liked Songs: \(export.likedSongs.count)")
        print("Unique tracks across everything: \(unique.count)  (missing ISRC: \(allTracks.filter { $0.isrc == nil }.count))")
        for p in export.playlists where p.skippedReason != nil && !p.skippedReason!.hasPrefix("Spotify-generated") {
            print("  skipped \(p.name): \(p.skippedReason!)")
        }
        print("Wrote \(exportDir.path)/spotify.json and spotify_tracks.csv")
    }

    // MARK: Auth (PKCE + loopback redirect)

    static func login(clientID: String) async throws -> (access: String, refresh: String?) {
        let verifier = randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = randomString(16)
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI), .init(name: "scope", value: scopes),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
        ]
        log("Opening Spotify login in your browser…")
        let codeTask = Task { try await waitForCallback(state: state) }
        NSWorkspace.shared.open(c.url!)
        let code = try await codeTask.value
        return try await token(form: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
            "client_id": clientID, "code_verifier": verifier,
        ])
    }

    static func refresh(clientID: String, refreshToken: String) async throws -> (access: String, refresh: String?) {
        try await token(form: ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID])
    }

    static func token(form: [String: String]) async throws -> (access: String, refresh: String?) {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = c.percentEncodedQuery!.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let access = json["access_token"] as? String else {
            throw SpotifyError.auth(json["error_description"] as? String ?? String(decoding: data, as: UTF8.self))
        }
        return (access, json["refresh_token"] as? String)
    }

    /// Minimal one-shot HTTP server on 127.0.0.1:8888 that captures ?code= from the redirect.
    static func waitForCallback(state: String) async throws -> String {
        let listener = try NWListener(using: .tcp, on: 8888)
        return try await withCheckedThrowingContinuation { cont in
            var done = false
            listener.newConnectionHandler = { conn in
                conn.start(queue: .main)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                    let line = String(decoding: data ?? Data(), as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                    let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let q = URLComponents(string: "http://x\(path)")?.queryItems ?? []
                    let code = q.first { $0.name == "code" }?.value
                    let ok = code != nil && q.first { $0.name == "state" }?.value == state
                    let body = ok ? "Spotify connected. You can close this tab." : "Login failed: \(q.first { $0.name == "error" }?.value ?? "unexpected request")"
                    let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n\(body)"
                    conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                    guard path.hasPrefix("/callback"), !done else { return }
                    done = true
                    listener.cancel()
                    if ok { cont.resume(returning: code!) } else { cont.resume(throwing: SpotifyError.auth(body)) }
                }
            }
            listener.start(queue: .main)
        }
    }

    // MARK: API client

    struct API {
        let token: String

        func get(_ pathOrURL: String) async throws -> [String: Any] {
            let url = pathOrURL.hasPrefix("https://") ? URL(string: pathOrURL)! : URL(string: "https://api.spotify.com/v1/\(pathOrURL)")!
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            for attempt in 0..<5 {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let http = resp as! HTTPURLResponse
                if http.statusCode == 429 {
                    let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(2 << attempt)
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                guard http.statusCode == 200 else {
                    let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
                    throw SpotifyError.http(http.statusCode, msg ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
                }
                return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            }
            throw SpotifyError.http(429, "rate limited")
        }

        func pages(_ path: String) async throws -> [[String: Any]] {
            var out: [[String: Any]] = []
            var next: String? = path
            while let n = next {
                let page = try await get(n)
                out += page["items"] as? [[String: Any]] ?? []
                next = page["next"] as? String
            }
            return out
        }
    }

    // MARK: Helpers

    static func loadConfig() -> Config? {
        if let id = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_ID"] { return Config(clientID: id, refreshToken: nil) }
        guard let d = try? Data(contentsOf: configFile) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: d)
    }

    static func saveConfig(_ c: Config) throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(c).write(to: configFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
    }

    static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<n).map { _ in chars.randomElement()! })
    }

    static func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
