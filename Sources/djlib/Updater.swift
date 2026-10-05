import AppKit
import Foundation
import SwiftUI

// Self-update for the Mac app: compares this build's code with GitHub (moloyb301-eng/wreckbox-mac) and, on
// request, pulls + rebuilds (scripts/update.sh) and relaunches. Library data is never touched.

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

    func check() {
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
