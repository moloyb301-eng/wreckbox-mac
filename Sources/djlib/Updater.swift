import AppKit
import Foundation
import SwiftUI

// Self-update for the Mac app. A shipped app (scripts/package-mac.sh) checks the latest GitHub release of
// moloyb301-eng/wreckbox-releases for a newer WreckBox-mac-arm64.zip and, on request, downloads it, swaps it in for
// this app and relaunches. A developer build compares its code with GitHub (moloyb301-eng/wreckbox-mac), pulls +
// rebuilds (scripts/update.sh) and relaunches. Library data is never touched.

@MainActor
final class Updater: ObservableObject {
    @Published var pending: [String] = []    // commit titles not yet installed
    @Published var updating = false
    @Published var message: String?
    private var timer: Timer?

    nonisolated private static func git(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", AppPaths.repo.path] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["GIT_TERMINAL_PROMPT"] = "0"   // never hang waiting for a password
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func start() {
        guard timer == nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.check() } }
    }

    static let releasesAPI = URL(string: "https://api.github.com/repos/moloyb301-eng/wreckbox-releases/releases/latest")!
    static let assetName = "WreckBox-mac-arm64.zip"
    private var release: (version: String, zip: URL)?

    static var installedVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// "0.6.10" > "0.6.9".
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : 0) != (i < y.count ? y[i] : 0) {
            return (i < x.count ? x[i] : 0) > (i < y.count ? y[i] : 0)
        }
        return false
    }

    private func checkRelease() {
        Task {
            var req = URLRequest(url: Self.releasesAPI)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
            guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = j["tag_name"] as? String else { return }   // offline: try later
            let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let asset = (j["assets"] as? [[String: Any]] ?? []).first { $0["name"] as? String == Self.assetName }
            guard Self.newer(version, than: Self.installedVersion), let u = asset?["browser_download_url"] as? String, let zip = URL(string: u) else {
                pending = []
                return
            }
            release = (version, zip)
            let notes = (j["body"] as? String ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }.map { String($0.dropFirst(2)) }
            pending = notes.isEmpty ? ["WreckBox \(version)"] : notes
        }
    }

    /// Downloads the release, checks it's a whole, signed WreckBox, puts it where this app is and relaunches.
    private func installRelease(stopSync: @escaping () -> Void) {
        guard let r = release else { return }
        message = "Downloading WreckBox \(r.version)…"
        Task {
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: r.zip)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw AccountAPI.Failure(message: "download failed") }
                let current = Bundle.main.bundleURL
                let ok = await Task.detached { () -> Bool in
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wreckbox-update-\(UUID().uuidString)")
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    func run(_ tool: String, _ args: [String]) -> Bool {
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: tool)
                        p.arguments = args
                        p.standardOutput = FileHandle.nullDevice
                        p.standardError = FileHandle.nullDevice
                        guard (try? p.run()) != nil else { return false }
                        p.waitUntilExit()
                        return p.terminationStatus == 0
                    }
                    let new = dir.appendingPathComponent("WreckBox.app")
                    guard run("/usr/bin/ditto", ["-x", "-k", tmp.path, dir.path]),
                          run("/usr/bin/codesign", ["--verify", "--deep", "--strict", new.path]) else { return false }
                    // The old copy goes to the Bin (recoverable), the new one takes its place.
                    var trashed: NSURL?
                    guard (try? FileManager.default.trashItem(at: current, resultingItemURL: &trashed)) != nil else { return false }
                    do { try FileManager.default.moveItem(at: new, to: current) } catch {
                        if let t = trashed as URL? { try? FileManager.default.moveItem(at: t, to: current) }   // put the old one back
                        return false
                    }
                    return true
                }.value
                guard ok else { throw AccountAPI.Failure(message: "the download wasn't a complete WreckBox") }
                stopSync()
                let relaunch = Process()
                relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
                relaunch.arguments = ["-c", "sleep 1.5; /usr/bin/open \"\(current.path)\""]
                try? relaunch.run()
                NSApp.terminate(nil)
            } catch {
                updating = false
                message = "Update failed: \(error.localizedDescription)"
            }
        }
    }

    func check() {
        if AppPaths.bundled { return checkRelease() }
        Task.detached(priority: .utility) {
            guard Self.git(["fetch", "--quiet", "origin", "main"]).0 == 0 else { return } // offline: try later
            // Compare with the code this app was BUILT from (the repo itself may be newer than the running app).
            let built = Bundle.main.object(forInfoDictionaryKey: "DJLibBuildCommit") as? String ?? "HEAD"
            let (_, log) = Self.git(["log", "--format=%s", "\(built.isEmpty ? "HEAD" : built)..origin/main"])
            let titles = log.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("Merge") }
            await MainActor.run { self.pending = titles }
        }
    }

    func updateAndRestart(stopSync: @escaping () -> Void) {
        updating = true
        if AppPaths.bundled { return installRelease(stopSync: stopSync) }
        message = "Downloading and building the update…"
        Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [AppPaths.repo.appendingPathComponent("scripts/update.sh").path]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            let ok: Bool
            do {
                try p.run()
                p.waitUntilExit()
                ok = p.terminationStatus == 0
            } catch {
                ok = false
            }
            let detail = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            await MainActor.run {
                guard ok else {
                    self.updating = false
                    self.message = "Update failed: " + (detail.split(separator: "\n").last.map(String.init) ?? "unknown error")
                    return
                }
                // Relaunch the freshly built app once this one has quit.
                stopSync()
                let app = AppPaths.repo.appendingPathComponent("build/WreckBox.app").path
                let relaunch = Process()
                relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
                relaunch.arguments = ["-c", "sleep 1.5; /usr/bin/open \"\(app)\""]
                try? relaunch.run()
                NSApp.terminate(nil)
            }
        }
    }
}

/// Banner shown while an update is waiting.
struct UpdateBanner: View {
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var store: LibraryStore
    @State private var expanded = false

    var body: some View {
        if !updater.pending.isEmpty || updater.message != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.smart)
                    Text(updater.pending.isEmpty ? "WreckBox" : "Update available — \(updater.pending.count) change\(updater.pending.count == 1 ? "" : "s")")
                        .font(Theme.ui(13, .semibold))
                    if !updater.pending.isEmpty {
                        Button(expanded ? "Hide" : "What's new") { expanded.toggle() }.buttonStyle(.plain)
                            .font(Theme.ui(12, .semibold)).foregroundStyle(Theme.text2)
                    }
                    Spacer()
                    if !updater.pending.isEmpty {
                        PillButton(label: updater.updating ? "Updating…" : "Update & restart", icon: "arrow.clockwise", style: .primary) {
                            guard !updater.updating else { return }
                            if store.soulseek.running {
                                let a = NSAlert()
                                a.messageText = "Restart now?"
                                a.informativeText = "Updating restarts WreckBox, which stops the Soulseek sync. Start it again after the restart."
                                a.addButton(withTitle: "Update & restart")
                                a.addButton(withTitle: "Later")
                                guard a.runModal() == .alertFirstButtonReturn else { return }
                            }
                            updater.updateAndRestart { if store.soulseek.running { store.stopSoulseek() } }
                        }
                    }
                }
                if let m = updater.message { Text(m).font(Theme.ui(12)).foregroundStyle(m.hasPrefix("Update failed") ? Theme.peach : Theme.text2) }
                if expanded {
                    ForEach(updater.pending.prefix(12), id: \.self) { t in
                        Text("• " + t).font(Theme.ui(12)).foregroundStyle(Theme.text2).lineLimit(2)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: 520, alignment: .leading)
            .smartGlass(18)
            .padding(16)
        }
    }
}
