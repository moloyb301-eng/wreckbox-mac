import AppKit
import CoreImage
import Foundation
import Network

// Computer → phone sync for the WreckBox phone app: the same small HTTP API as the cross-platform desktop
// app (port 47390, pairing token in the QR code), serving this Mac's crate.
//
//   GET /info            {"name", "tracks"}
//   GET /library.json    the library (so a new phone can adopt it)
//   GET /crate           [{"id", "ext", "size", "analysis"}] for every track with a file
//   GET /file/<id>       the audio file (supports Range, so the phone can seek while streaming)
//   GET /art/<id>        cached cover
// Every request must carry the token (header X-WreckBox-Token or ?t=).

final class PhoneSyncServer: ObservableObject {
    static let port: UInt16 = 47390
    @Published private(set) var running = false
    @Published var lastError: String?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "wreckbox.phonesync")
    weak var store: LibraryStore?

    /// Snapshot of what the phone may download (taken on the main actor, read on the server queue).
    private var crate: [String: (path: String, analysis: Data?)] = [:]

    var token: String {
        if let t = UserDefaults.standard.string(forKey: "phoneSyncToken") { return t }
        let t = Self.newToken()
        UserDefaults.standard.set(t, forKey: "phoneSyncToken")
        return t
    }

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func resetToken() { UserDefaults.standard.set(Self.newToken(), forKey: "phoneSyncToken"); objectWillChange.send() }

    /// Private-network IPv4 addresses a phone on the same Wi-Fi can reach.
    static func localAddresses() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.range(of: #"^172\.(1[6-9]|2\d|3[01])\."#, options: .regularExpression) != nil {
                out.append(ip)
            }
        }
        return out
    }

    var pairingURI: String {
        "wreckbox://pair?hosts=\(Self.localAddresses().joined(separator: ","))&port=\(Self.port)&t=\(token)"
    }

    @MainActor func refreshCrate() {
        guard let store else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var c: [String: (String, Data?)] = [:]
        for t in store.library?.tracks ?? [] {
            guard let st = store.state.tracks[t.id], st.status == .downloaded, let path = st.localPath,
                  FileManager.default.fileExists(atPath: path) else { continue }
            c[t.id] = (path, store.analysis[path].flatMap { try? enc.encode($0) })
        }
        let snapshot = c
        queue.async { self.crate = snapshot.mapValues { (path: $0.0, analysis: $0.1) } }
    }

    @MainActor func start() {
        guard listener == nil else { return }
        refreshCrate()
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.newConnectionHandler = { [weak self] c in self?.handle(c) }
            l.stateUpdateHandler = { [weak self] s in
                DispatchQueue.main.async {
                    switch s {
                    case .ready: self?.running = true; self?.lastError = nil
                    case .failed(let e): self?.running = false; self?.lastError = "Couldn't start sharing: \(e.localizedDescription)"; self?.listener = nil
                    case .cancelled: self?.running = false
                    default: break
                    }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            lastError = "Couldn't start sharing: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    // MARK: HTTP

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        readRequest(c, buffer: Data())
    }

    private func readRequest(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(c, head: String(decoding: buf[..<end.lowerBound], as: UTF8.self))
            } else if done || err != nil || buf.count > 65_536 {
                c.cancel()
            } else {
                self.readRequest(c, buffer: buf)
            }
        }
    }

    private func respond(_ c: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let url = URLComponents(string: "http://x" + parts[1]) else {
            return send(c, status: "400 Bad Request", body: Data("bad request".utf8))
        }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) }
        }
        let given = headers["x-wreckbox-token"] ?? url.queryItems?.first { $0.name == "t" }?.value
        guard given == token else { return send(c, status: "403 Forbidden", body: Data("not paired".utf8)) }
        let path = url.path
        if path == "/info" {
            let body = try? JSONSerialization.data(withJSONObject: ["name": "WreckBox on \(Host.current().localizedName ?? "Mac")", "tracks": crate.count])
            return send(c, status: "200 OK", type: "application/json", body: body ?? Data())
        }
        if path == "/library.json" {
            let body = (try? Data(contentsOf: libraryRoot.appendingPathComponent("library.json"))) ?? Data()
            return send(c, status: "200 OK", type: "application/json", body: body)
        }
        if path == "/crate" {
            var items: [[String: Any]] = []
            for (id, v) in crate {
                let size = ((try? FileManager.default.attributesOfItem(atPath: v.path)[.size]) as? NSNumber)?.intValue ?? 0
                var item: [String: Any] = ["id": id, "ext": "." + (v.path as NSString).pathExtension.lowercased(), "size": size]
                if let a = v.analysis, let j = try? JSONSerialization.jsonObject(with: a) { item["analysis"] = j }
                items.append(item)
            }
            let body = (try? JSONSerialization.data(withJSONObject: items)) ?? Data("[]".utf8)
            return send(c, status: "200 OK", type: "application/json", body: body)
        }
        if path.hasPrefix("/art/") {
            let id = String(path.dropFirst(5)).removingPercentEncoding ?? ""
            let f = ArtworkLoader.dir.appendingPathComponent(ArtworkLoader.fileStem(id) + ".jpg")
            guard let data = try? Data(contentsOf: f) else { return send(c, status: "404 Not Found", body: Data()) }
            return send(c, status: "200 OK", type: "image/jpeg", body: data)
        }
        if path.hasPrefix("/file/") {
            let id = String(path.dropFirst(6)).removingPercentEncoding ?? ""
            guard let file = crate[id]?.path, let h = FileHandle(forReadingAtPath: file) else {
                return send(c, status: "404 Not Found", body: Data("no such track".utf8))
            }
            let len = ((try? FileManager.default.attributesOfItem(atPath: file)[.size]) as? NSNumber)?.intValue ?? 0
            var start = 0, end = len - 1, status = "200 OK"
            var extra = "Accept-Ranges: bytes\r\n"
            if let r = headers["range"], let m = r.range(of: #"bytes=(\d*)-(\d*)"#, options: .regularExpression) {
                let spec = r[m].dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                let a = Int(spec.first ?? ""), b = spec.count > 1 ? Int(spec[1]) : nil
                if let a { start = a; end = min(b ?? len - 1, len - 1) } else if let b { start = max(0, len - b) }
                guard start <= end else {
                    try? h.close()
                    return send(c, status: "416 Range Not Satisfiable", body: Data())
                }
                status = "206 Partial Content"
                extra += "Content-Range: bytes \(start)-\(end)/\(len)\r\n"
            }
            let header = "HTTP/1.1 \(status)\r\nContent-Type: \(Self.mime(file))\r\nContent-Length: \(end - start + 1)\r\n\(extra)Connection: close\r\n\r\n"
            try? h.seek(toOffset: UInt64(start))
            c.send(content: Data(header.utf8), completion: .contentProcessed { _ in self.stream(c, h, remaining: end - start + 1) })
            return
        }
        send(c, status: "404 Not Found", body: Data())
    }

    /// Sends the file in 256 KB chunks, one after another, so large FLACs don't sit in memory.
    private func stream(_ c: NWConnection, _ h: FileHandle, remaining: Int) {
        guard remaining > 0, let chunk = try? h.read(upToCount: min(262_144, remaining)), !chunk.isEmpty else {
            try? h.close()
            c.send(content: nil, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
            return
        }
        c.send(content: chunk, completion: .contentProcessed { [weak self] err in
            if err != nil { try? h.close(); c.cancel(); return }
            self?.stream(c, h, remaining: remaining - chunk.count)
        })
    }

    private func send(_ c: NWConnection, status: String, type: String = "text/plain", body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }

    static func mime(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "flac": return "audio/flac"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac", "alac": return "audio/mp4"
        case "wav": return "audio/wav"
        case "aif", "aiff": return "audio/aiff"
        default: return "application/octet-stream"
        }
    }

    static func qr(_ text: String, size: CGFloat) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: size / out.extent.width, y: size / out.extent.height))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

import SwiftUI

/// "Sync to phone": start / stop sharing, QR code + pairing link for the WreckBox phone app.
struct PhoneSyncView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var server: PhoneSyncServer
    @State private var copied = false

    var body: some View {
        let uri = server.pairingURI
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(eyebrow: "Tools", title: "Sync to phone",
                       subtitle: "Send tracks from this Mac to the WreckBox phone app over your Wi-Fi") {
                PillButton(label: server.running ? "Stop sharing" : "Start sharing",
                           icon: server.running ? "stop.fill" : "antenna.radiowaves.left.and.right",
                           style: server.running ? .glass : .smart) {
                    server.running ? server.stop() : server.start()
                }
            }
            if let e = server.lastError { Text(e).font(Theme.ui(13, .semibold)).foregroundStyle(Theme.peach) }
            HStack(alignment: .top, spacing: 24) {
                Group {
                    if server.running, let img = PhoneSyncServer.qr(uri, size: 220) {
                        Image(nsImage: img).interpolation(.none).resizable().frame(width: 220, height: 220)
                            .padding(10).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Text("Start sharing to show the pairing code").font(Theme.ui(13)).foregroundStyle(Theme.text3)
                            .multilineTextAlignment(.center).frame(width: 240, height: 240)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("On your phone").font(Theme.ui(18, .semibold))
                    ForEach(Array(["Connect the phone to the same Wi-Fi as this Mac.",
                                   "Open WreckBox → Computer → Scan pairing code.",
                                   "Pick playlists and tap Download, or tap a cover to stream it."].enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(i + 1)").font(Theme.dot(15)).foregroundStyle(Theme.lilac)
                            Text(s).font(Theme.ui(13)).foregroundStyle(Theme.text2)
                        }
                    }
                    if server.running {
                        Text("Camera won't read it? On the phone tap \"Enter pairing link\" and paste:").font(Theme.ui(12)).foregroundStyle(Theme.text2).padding(.top, 6)
                        HStack {
                            Text(uri).font(Theme.ui(11.5)).foregroundStyle(Theme.text3).textSelection(.enabled).lineLimit(3)
                            PillButton(label: copied ? "Copied" : "Copy", icon: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(uri, forType: .string)
                                copied = true
                            }
                        }
                        Text("Sharing \(store.count(.downloaded)) tracks. New downloads are added automatically.")
                            .font(Theme.ui(12)).foregroundStyle(Theme.text3)
                    }
                    Text("Only phones that scanned this code can connect. macOS may ask to allow incoming connections — allow it.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.text3).padding(.top, 6)
                    PillButton(label: "Unpair all phones", icon: "link.badge.plus") {
                        server.resetToken()
                        if server.running { server.stop(); server.start() }
                    }
                }
            }
            .padding(22)
            .glass(Theme.Radius.card)
            Spacer()
        }
        .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 10)
        .onReceive(store.$state) { _ in if server.running { server.refreshCrate() } }
    }
}
