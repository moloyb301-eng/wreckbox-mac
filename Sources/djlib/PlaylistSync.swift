import Foundation

// Keeps the library in step with your Spotify playlists: re-imports them and rebuilds library.json.
// Runs every morning at 07:00 (a launchd job the app installs; if the Mac was asleep it runs on wake), on launch
// when today's sync was missed, and from the "Sync playlists" button. The app reloads whenever library.json
// changes, and nudges slsk-sync so new tracks are searched for straight away.

enum PlaylistSync {
    static let agentLabel = "local.wreckbox.playlist-sync"
    static var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }
    static var stampFile: URL { SpotifyImport.exportDir.appendingPathComponent("last_sync.txt") }
    static let morningHour = 7

    /// Spotify → spotify.json → library.json. Heavy; call off the main thread.
    static func run() async throws {
        try await SpotifyImport.run(args: [])
        try buildLibrary()
        try ISO8601DateFormatter().string(from: Date()).write(to: stampFile, atomically: true, encoding: .utf8)
    }

    static var lastSync: Date? {
        (try? String(contentsOf: stampFile, encoding: .utf8)).flatMap { ISO8601DateFormatter().date(from: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// True after 07:00 when there's been no sync since this morning's 07:00.
    static var due: Bool {
        let cal = Calendar.current
        let now = Date()
        guard let morning = cal.date(bySettingHour: morningHour, minute: 0, second: 0, of: now), now >= morning else { return false }
        return (lastSync ?? .distantPast) < morning
    }

    /// Installs (or updates) the 07:00 launchd job that runs `djlib sync-playlists` with this app's binary.
    static func installAgent() {
        guard let exe = Bundle.main.executableURL?.path, exe.contains(".app/") else { return }   // only from the app
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WreckBox-playlists.log").path
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [exe, "sync-playlists"],
            "StartCalendarInterval": ["Hour": morningHour, "Minute": 0],
            "StandardOutPath": log,
            "StandardErrorPath": log,
            "ProcessType": "Background",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        if (try? Data(contentsOf: agentPlist)) == data { return }   // already installed for this binary
        try? FileManager.default.createDirectory(at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: agentPlist, options: .atomic)
        let uid = getuid()
        for args in [["bootout", "gui/\(uid)/\(agentLabel)"], ["bootstrap", "gui/\(uid)", agentPlist.path]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }
}

extension LibraryStore {
    /// "Sync playlists" button, and the catch-up when this morning's sync was missed.
    func syncPlaylists() async {
        guard busy == nil else { return }
        busy = "Syncing playlists from Spotify…"
        let before = Set((library?.tracks ?? []).map(\.id))
        do {
            try await Task.detached(priority: .userInitiated) { try await PlaylistSync.run() }.value
            reloadLibrary()
            let added = (library?.tracks ?? []).filter { !before.contains($0.id) }.count
            log("spotify", nil, added == 0 ? "playlists synced — nothing new" : "playlists synced — \(added) new tracks")
        } catch {
            log("spotify", nil, "playlist sync failed: \(error.localizedDescription)")
        }
        busy = nil
        save()
        await rebuildGenresAndOrganise()   // genres for the new tracks (cached lookups make this quick), folders, tags
    }

    /// Re-reads library.json only (state and analysis stay as they are in memory).
    func reloadLibrary() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let url = libraryRoot.appendingPathComponent("library.json")
        guard let lib = try? dec.decode(Library.self, from: Data(contentsOf: url)) else { return }
        library = lib
        libraryLoadedAt = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
        writeQueue()   // slsk-sync wakes when the queue changes, so new tracks are searched for now
    }

    /// Called from the periodic watcher: picks up library.json written by the morning job (or the CLI).
    func reloadLibraryIfChanged() {
        let url = libraryRoot.appendingPathComponent("library.json")
        guard let m = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date else { return }
        if let loaded = libraryLoadedAt, m <= loaded { return }
        if libraryLoadedAt == nil { libraryLoadedAt = m; return }   // first look: what reload() read at launch
        reloadLibrary()
        log("spotify", nil, "library updated from Spotify")
    }
}
