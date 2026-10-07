import AppKit
import SwiftUI

// First-run setup for a new Mac (also under WreckBox → Setup…): where the library lives, the person's own
// Soulseek, Spotify and YouTube logins, and what macOS will ask. Every login is theirs and stays on their Mac —
// the app ships with none (no Spotify app or account of the developer is used; each person makes their own free
// Spotify developer app, which takes a minute).

enum Setup {
    static var done: Bool {
        get { UserDefaults.standard.bool(forKey: "setupDone") }
        set { UserDefaults.standard.set(newValue, forKey: "setupDone") }
    }

    /// Connects Spotify with the person's own developer app (Client ID), signing in in their browser.
    static func connectSpotify(clientID: String) async throws {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil else {
            throw AccountAPI.Failure(message: "A Client ID is 32 letters and numbers — copy it from your app's page on developer.spotify.com.")
        }
        let t = try await SpotifyImport.login(clientID: id)
        try SpotifyImport.saveConfig(.init(clientID: id, refreshToken: t.refresh))
    }

    static var spotifyConnected: Bool { SpotifyImport.loadConfig()?.refreshToken != nil }

    static func disconnectSpotify() { try? FileManager.default.removeItem(at: SpotifyImport.configFile) }

    /// The browser yt-fill reads the YouTube login from (_youtube/config.json "browser").
    static var youtubeBrowser: String {
        get {
            let f = libraryRoot.appendingPathComponent("_youtube/config.json")
            let j = (try? JSONSerialization.jsonObject(with: Data(contentsOf: f))) as? [String: Any]
            return j?["browser"] as? String ?? "chrome"
        }
        set {
            let f = libraryRoot.appendingPathComponent("_youtube/config.json")
            var j = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: f))) as? [String: Any]) ?? [:]
            j["browser"] = newValue
            try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]).write(to: f, options: .atomic)
        }
    }
}

struct SetupView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var spotifyBusy = false
    @State private var spotifyMessage: String?
    @State private var connected = Setup.spotifyConnected
    @State private var browser = Setup.youtubeBrowser

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                DotLabel("Welcome")
                Text("Set up WreckBox").font(Theme.ui(30, .medium)).foregroundStyle(Theme.text)
                Text("Everything below is optional and can be changed later (WreckBox → Setup…). Your logins stay on this Mac.")
                    .font(Theme.ui(13)).foregroundStyle(Theme.text2)
            }
            .padding(24)
            Scroller {
                VStack(alignment: .leading, spacing: 14) {
                    step("1", "Your library", "music.note.house") {
                        Text("Music goes to **Music/DJ Library** in your home folder: Tracks/ sorted into genre folders, tagged with BPM, key and energy for Rekordbox.")
                            .font(Theme.ui(13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        PillButton(label: "Show in Finder", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([libraryRoot]) }
                    }
                    step("2", "Playlists", "music.note.list") {
                        Text("Add playlists from **Spotify, YouTube or YouTube Music links** (the + next to Playlists). WreckBox finds every track and keeps the playlist up to date each morning.")
                            .font(Theme.ui(13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        spotify
                    }
                    step("3", "Soulseek", "point.3.connected.trianglepath.dotted") {
                        Text("Tracks come from Soulseek first, in the best quality there is (FLAC when anyone has it).")
                            .font(Theme.ui(13)).foregroundStyle(Theme.text2)
                        if store.soulseek.configured {
                            Label("Signed in", systemImage: "checkmark.circle.fill").font(Theme.ui(13, .semibold)).foregroundStyle(Theme.lilac)
                        } else {
                            SoulseekLogin()
                        }
                    }
                    step("4", "YouTube", "play.rectangle") {
                        Text("What Soulseek doesn't have comes from YouTube Music (official audio; better quality with YouTube Premium). WreckBox uses the YouTube login in your browser — sign in to YouTube there first.")
                            .font(Theme.ui(13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        Picker("Browser", selection: $browser) {
                            Text("Chrome").tag("chrome"); Text("Brave").tag("brave"); Text("Edge").tag("edge"); Text("Firefox").tag("firefox"); Text("Safari").tag("safari")
                        }
                        .frame(width: 240)
                        .onChange(of: browser) { Setup.youtubeBrowser = $0 }
                        Text(browser == "safari"
                             ? "Safari: allow WreckBox in System Settings → Privacy & Security → Full Disk Access, or it can't read the login."
                             : "The first time, macOS asks to let WreckBox use \"\(browser.capitalized) Safe Storage\" — enter your Mac password and choose Always Allow.")
                            .font(Theme.ui(12)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    }
                    step("5", "Before you download", "shield.lefthalf.filled") {
                        Text("Turn on a VPN before downloading — Soulseek shows your IP address to the people you download from. WreckBox reminds you each time a download starts.")
                            .font(Theme.ui(13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        Text("macOS may also ask to allow incoming network connections (for Soulseek and your phone) — allow them.")
                            .font(Theme.ui(12)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 12)
            }
            HStack {
                Spacer()
                PillButton(label: "Done", icon: "checkmark", style: .primary) {
                    Setup.done = true
                    dismiss()
                }
            }
            .padding(20)
        }
        .frame(width: 640, height: 720)
        .background(Theme.bg)
    }

    @ViewBuilder private var spotify: some View {
        if connected {
            HStack(spacing: 10) {
                Label("Spotify connected — your playlists and Liked Songs sync every morning", systemImage: "checkmark.circle.fill")
                    .font(Theme.ui(13, .semibold)).foregroundStyle(Theme.lilac)
                Spacer()
                PillButton(label: "Disconnect", icon: "xmark") { Setup.disconnectSpotify(); connected = false }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Optional — connect **your own** Spotify to sync all your playlists and Liked Songs (needed for private Spotify playlists):")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("1. Open developer.spotify.com/dashboard, log in, Create app (any name).")
                    Text("2. Redirect URI: \(SpotifyImport.redirectURI) — tick Web API — Save.")
                    Text("3. Copy the Client ID from the app's page and paste it here.")
                }
                .font(Theme.ui(12)).foregroundStyle(Theme.text3)
                .textSelection(.enabled)
                HStack(spacing: 8) {
                    PillButton(label: "Open Spotify dashboard", icon: "safari") { NSWorkspace.shared.open(URL(string: "https://developer.spotify.com/dashboard")!) }
                    TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder).frame(width: 260)
                    PillButton(label: spotifyBusy ? "Waiting for Spotify…" : "Connect", icon: "link", style: .smart) {
                        guard !spotifyBusy else { return }
                        spotifyBusy = true
                        spotifyMessage = nil
                        Task {
                            do {
                                try await Setup.connectSpotify(clientID: clientID)
                                connected = true
                                Task { await store.syncPlaylists() }
                            } catch {
                                spotifyMessage = error.localizedDescription
                            }
                            spotifyBusy = false
                        }
                    }
                    .disabled(clientID.isEmpty)
                }
                if let spotifyMessage { Text(spotifyMessage).font(Theme.ui(12)).foregroundStyle(Theme.peach) }
            }
        }
    }

    private func step<C: View>(_ n: String, _ title: String, _ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(n).font(Theme.dot(16)).foregroundStyle(Theme.lilac).frame(width: 22)
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: icon).font(Theme.ui(16, .semibold)).foregroundStyle(Theme.text)
                content()
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(Theme.Radius.tile)
    }
}
