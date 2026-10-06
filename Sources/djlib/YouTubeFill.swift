import Foundation

// YouTube fill (youtube/yt-fill): gets the tracks Soulseek couldn't find from YouTube Music — official audio
// only, in your Premium quality — and hands them over through _inbox like slsk-sync. On by default; it runs
// next to the Soulseek sync and only takes tracks Soulseek has already tried.

struct YouTubeStatus {
    var running = false
    var done = 0, notFound = 0, failed = 0
    var recent: [String] = []
    /// Track ids it got (so imports are recorded as coming from YouTube).
    var got: Set<String> = []
}

extension AppPaths {
    static var ytFill: URL { repo.appendingPathComponent("youtube/yt-fill") }
    static let ytWorkDir = libraryRoot.appendingPathComponent("_youtube")
}

extension LibraryStore {
    /// The switch on the Soulseek tile (on unless turned off).
    var youtubeFillEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "youtubeFill") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "youtubeFill") }
    }

    func refreshYouTube() {
        var s = YouTubeStatus()
        let recs = (try? JSONSerialization.jsonObject(with: Data(contentsOf: AppPaths.ytWorkDir.appendingPathComponent("yt.json")))) as? [String: [String: Any]] ?? [:]
        for (id, r) in recs {
            switch r["status"] as? String {
            case "done": s.done += 1; s.got.insert(id)
            case "not_found": s.notFound += 1
            case "failed": s.failed += 1
            default: break
            }
        }
        s.recent = Self.tail(AppPaths.ytWorkDir.appendingPathComponent("yt.log"), lines: 20).reversed()
        s.running = Self.ytProcess?.isRunning == true || Self.ytLockHolder() != nil
        youtube = s
    }

    /// PID of a yt-fill holding its lock (e.g. started from Terminal), or nil.
    nonisolated static func ytLockHolder() -> Int32? {
        let fd = open(AppPaths.ytWorkDir.appendingPathComponent("yt.lock").path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 { flock(fd, LOCK_UN); return nil }
        let text = (try? String(contentsOf: AppPaths.ytWorkDir.appendingPathComponent("yt.pid"), encoding: .utf8)) ?? ""
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    func startYouTubeFill() {
        youtubeFillEnabled = true
        guard Self.ytProcess?.isRunning != true, Self.ytLockHolder() == nil,
              FileManager.default.isExecutableFile(atPath: AppPaths.ytFill.path) else { refreshYouTube(); return }
        let p = Process()
        p.executableURL = AppPaths.ytFill
        p.arguments = ["run"]
        // ffmpeg / deno (yt-dlp's YouTube challenge solver) live in Homebrew, which apps don't have on their PATH.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        p.standardOutput = FileHandle.nullDevice   // it writes its own log
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in Task { @MainActor [weak self] in self?.refreshYouTube() } }
        do {
            try p.run()
            Self.ytProcess = p
            log("youtube", nil, "YouTube fill started")
        } catch {
            log("youtube", nil, "couldn't start yt-fill: \(error.localizedDescription)")
        }
        refreshYouTube()
    }

    func stopYouTubeFill() {
        youtubeFillEnabled = false
        Self.ytProcess?.terminate()
        if let pid = Self.ytLockHolder(), pid > 0 { kill(pid, SIGTERM) }
        log("youtube", nil, "YouTube fill stopped")
        refreshYouTube()
    }

    /// "Get from YouTube now" — yt-fill wakes within a few seconds and does these first.
    func requestYouTube(_ ids: [String]) {
        let url = AppPaths.ytWorkDir.appendingPathComponent("requests.json")
        var all = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: String] ?? [:]
        let now = ISO8601DateFormatter().string(from: Date())
        ids.forEach { all[$0] = now }
        try? FileManager.default.createDirectory(at: AppPaths.ytWorkDir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url, options: .atomic) }
        log("youtube", ids.count == 1 ? ids[0] : nil, ids.count == 1 ? "asked YouTube for \(describe(ids[0]))" : "asked YouTube for \(ids.count) tracks")
        if !youtube.running { startYouTubeFill() }
    }
}
