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

import SwiftUI

/// Home / YouTube page tile: what YouTube fill is doing.
struct YouTubeTile: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        let y = store.youtube
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "play.rectangle.fill").font(.system(size: 17, weight: .regular)).foregroundStyle(Theme.smart)
                    .frame(width: 22, alignment: .leading)
                DotLabel("YouTube", color: Theme.text)
                Spacer()
                PillButton(label: y.running ? "Turn off" : "Turn on", icon: y.running ? "stop.fill" : "play.fill", style: y.running ? .glass : .smart) {
                    y.running ? store.stopYouTubeFill() : store.startYouTubeFill()
                }
                .help("Get tracks Soulseek can't find from YouTube Music — official audio only, in your Premium quality")
            }
            Text(YouTubeTile.statusLine(y)).font(Theme.ui(12.5)).foregroundStyle(Theme.text2).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 22) {
                SyncCounter(label: "Got", n: y.done)
                SyncCounter(label: "Not on YouTube", n: y.notFound)
                SyncCounter(label: "Failed", n: y.failed)
            }
        }
        .padding(16)
        .smartGlass(Theme.Radius.tile)
    }

    static func statusLine(_ y: YouTubeStatus) -> String {
        guard y.running else { return "Off. Fills what Soulseek can't find from YouTube Music — official audio, Premium quality." }
        guard let last = y.recent.first else { return "Starting…" }
        let text = String(last.dropFirst(20))
        if text.hasPrefix("⏸") { return "Waiting for your YouTube login — allow the keychain prompt (Chrome Safe Storage)." }
        return text
    }
}

struct SyncCounter: View {
    let label: String
    let n: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(n)").font(Theme.dot(20)).monospacedDigit()
            DotLabel(label, size: 9)
        }
    }
}

/// Full YouTube page: status, switch, how it works, live log.
struct YouTubeView: View {
    @EnvironmentObject var store: LibraryStore
    /// "Find manually" (search / paste a link for tracks nothing found) or the automatic fill's activity.
    @State private var manual = true

    var body: some View {
        let y = store.youtube
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(eyebrow: "Sources", title: "YouTube",
                       subtitle: y.running ? "On — fills tracks Soulseek couldn't find, every 30 minutes" : "Off") {
                HStack(spacing: 8) {
                    PillButton(label: "Find manually", icon: "magnifyingglass", style: manual ? .primary : .glass) { manual = true }
                    PillButton(label: "Activity", icon: "list.bullet", style: manual ? .glass : .primary) { manual = false }
                    PillButton(label: y.running ? "Turn off" : "Turn on", icon: y.running ? "stop.fill" : "play.fill", style: y.running ? .glass : .smart) {
                        y.running ? store.stopYouTubeFill() : store.startYouTubeFill()
                    }
                }
            }
            if manual { YouTubeFindView() } else { activity }
        }
        .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 10)
    }

    @ViewBuilder private var activity: some View {
        let y = store.youtube
        VStack(alignment: .leading, spacing: 16) {
            YouTubeTile()
            VStack(alignment: .leading, spacing: 8) {
                DotLabel("How it works", color: Theme.text)
                Text("Only tracks Soulseek already tried and couldn't get. Only the artist's official audio on YouTube Music — never music videos — with matching title, artist and length. Your Premium login (from Chrome) gives Opus at ~260–330 kbps, kept as Opus (.opus) — nothing is converted. Rekordbox can't play Opus; a real FLAC from Soulseek replaces it when the weekly upgrade search finds one. Without the login it waits instead of downloading in lower quality.")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .glass(Theme.Radius.tile)
            LogPanel(lines: y.recent)
        }
    }
}

/// The scrolling log used by the Soulseek and YouTube pages.
struct LogPanel: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DotLabel("Log")
            Scroller {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if lines.isEmpty { Text("No activity yet.").foregroundStyle(Theme.text3) }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(color(line)).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .glass(Theme.Radius.card)
    }

    private func color(_ line: String) -> Color {
        if line.contains("✓") { return Theme.lilac }
        if line.contains("✗") || line.contains("failed") || line.contains("⏸") { return Theme.peach }
        return Theme.text2
    }
}
