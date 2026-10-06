import Foundation

// Direct Wi-Fi copy: when the phone and this Mac aren't on the same Wi-Fi, the phone hosts a Wi-Fi Direct group
// (an access point named DIRECT-…, 192.168.49.x) and asks this Mac — through the tunnel — to join it. Macs can't
// do Wi-Fi Direct themselves but join the group like any network. A Mac's Wi-Fi is on one network at a time, so
// while it's on the phone's link it has no internet; it goes back to its usual Wi-Fi when the phone is done, or by
// itself after a few idle minutes so it's never left stranded.
enum DirectWiFi {
    /// Wi-Fi Direct group owners hand out 192.168.49.x.
    static let subnet = "192.168.49."
    private static let queue = DispatchQueue(label: "wreckbox.direct")
    private static var joinedSSID: String?
    private static var lastActivity = Date()
    private static var watchdog: DispatchSourceTimer?

    static var onDirect: Bool { PhoneSyncServer.localAddresses().contains { $0.hasPrefix(subnet) } }

    /// The Wi-Fi interface (en0 on most Macs).
    static let device: String = {
        let out = run(["-listallhardwareports"]).output
        var wifi = false
        for line in out.components(separatedBy: "\n") {
            if line.hasPrefix("Hardware Port:") { wifi = line.contains("Wi-Fi") || line.contains("AirPort") }
            if wifi, line.hasPrefix("Device:") { return line.dropFirst(7).trimmingCharacters(in: .whitespaces) }
        }
        return "en0"
    }()

    /// Only Wi-Fi Direct group names, so a phone can't send this Mac to some other network.
    static func valid(ssid: String, pass: String) -> Bool {
        ssid.hasPrefix("DIRECT-") && ssid.count <= 32 && (8...63).contains(pass.count)
    }

    /// Joins the phone's group (shortly after the reply to the phone is on its way).
    static func join(ssid: String, pass: String) {
        queue.asyncAfter(deadline: .now() + 1) {
            RemoteAccess.log("direct: joining \(ssid)")
            var r = (status: Int32(1), output: "")
            for attempt in 1...4 {   // the group may take a moment to start beaconing
                r = run(["-setairportnetwork", device, ssid, pass])
                if r.status == 0 && !r.output.contains("Could not") && !r.output.contains("Error") { break }
                RemoteAccess.log("direct: join attempt \(attempt) failed: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
                Thread.sleep(forTimeInterval: 3)
            }
            joinedSSID = ssid
            touch()
            startWatchdog()
        }
    }

    /// Back to the usual Wi-Fi: forget the phone's group and restart Wi-Fi so macOS picks its known network again.
    static func leave(after delay: Double = 1) {
        queue.asyncAfter(deadline: .now() + delay) {
            guard let ssid = joinedSSID ?? (onDirect ? "" : nil) else { return }
            RemoteAccess.log("direct: leaving \(ssid)")
            if !ssid.isEmpty { _ = run(["-removepreferredwirelessnetwork", device, ssid]) }
            joinedSSID = nil
            watchdog?.cancel()
            watchdog = nil
            if onDirect {
                _ = run(["-setairportpower", device, "off"])
                Thread.sleep(forTimeInterval: 2)
                _ = run(["-setairportpower", device, "on"])
            }
        }
    }

    /// Every phone request while on the direct link counts as activity.
    static func touch() { queue.async { lastActivity = Date() } }

    /// Leaves after 3 idle minutes (the phone app was closed, or the phone walked away).
    private static func startWatchdog() {
        watchdog?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler {
            guard joinedSSID != nil else { return }
            if Date().timeIntervalSince(lastActivity) > 180 {
                RemoteAccess.log("direct: idle for 3 min")
                leave(after: 0)
            }
        }
        t.resume()
        watchdog = t
    }

    @discardableResult
    private static func run(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
