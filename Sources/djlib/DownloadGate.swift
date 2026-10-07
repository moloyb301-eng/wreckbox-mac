import AppKit

// Before anything is downloaded (Soulseek, YouTube, SoundCloud — a manual download, turning a source on, a retry,
// or the sources resuming at launch): a reminder to turn a VPN on. Soulseek shows your IP address to other users
// and shares files back; YouTube downloads come from your connection too. "Don't ask again today" quiets it
// until tomorrow. It only appears when a download is about to start.
@MainActor
enum DownloadGate {
    private static let key = "vpnAcknowledgedDay"
    private static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// True to go ahead. Shows the reminder unless it was acknowledged for today.
    static func allow() async -> Bool {
        if UserDefaults.standard.string(forKey: key) == today { return true }
        let a = NSAlert()
        a.messageText = "Turn on your VPN before downloading"
        a.informativeText = "Soulseek shows your IP address to the people you download from (and shares your files back), and YouTube downloads come from your own connection. Connect your VPN first, then carry on."
        a.alertStyle = .warning
        a.addButton(withTitle: "My VPN is on — download")
        a.addButton(withTitle: "Cancel")
        a.showsSuppressionButton = true
        a.suppressionButton?.title = "Don't ask again today"
        NSApp.activate(ignoringOtherApps: true)
        let ok = a.runModal() == .alertFirstButtonReturn
        if ok, a.suppressionButton?.state == .on { UserDefaults.standard.set(today, forKey: key) }
        return ok
    }

    /// For buttons: runs `action` once the reminder is accepted.
    static func then(_ action: @escaping () -> Void) {
        Task { @MainActor in if await allow() { action() } }
    }
}
