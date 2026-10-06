import AppKit
import Combine
import CommonCrypto
import CoreImage
import Foundation
import Network

// Computer → phone sync for the WreckBox phone app (port 47390). Reached on the same Wi-Fi with the pairing token
// from the QR code, or from anywhere through the Cloudflare tunnel with a short-lived ticket the account service
// signs with this Mac's ticket secret. Credentials travel only in headers (Authorization: Bearer …).
//
//   GET  /info                 {"name", "tracks", "lan", "port", "qualities"}
//   GET  /library.json         the library (so a new phone can adopt it)
//   GET  /crate                [{"id", "ext", "size", "analysis"}] for every track with a file
//   GET  /file/<id>?q=flac|high|med|low   the audio (Range supported); high/med/low are AAC copies
//   GET  /art/<id>             cached cover
//   GET  /poll?after=<seq>     live updates by long polling: answers as soon as there's news (crate added /
//                              removed, request status), or after 25 s with none. (Cloudflare quick tunnels hold
//                              back streamed responses, so a held-open stream can't be used.)
//   POST /prepare {"ids", "q"} make the copies for the phone's next tracks ahead of time
//   POST /request {"id"} or {"artist", "title", "query"}   look for a track on Soulseek now
//   GET  /requests             status of the phone's requests

final class PhoneSyncServer: ObservableObject {
    /// WRECKBOX_SYNC_PORT moves it for testing next to a running app.
    static let port: UInt16 = UInt16(ProcessInfo.processInfo.environment["WRECKBOX_SYNC_PORT"] ?? "") ?? 47390
    @Published private(set) var running = false
    @Published var lastError: String?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "wreckbox.phonesync")
    private var cancellables: Set<AnyCancellable> = []
    weak var store: LibraryStore?

    /// Snapshot of what the phone may download (taken on the main actor, read on the server queue).
    private var crate: [String: (path: String, analysis: Data?)] = [:]
    /// Recent events for /poll (server queue only): sequence number, name, data.
    private var events: [(seq: Int, name: String, data: Any)] = []
    private var seq = 0
    /// Phones waiting in /poll for the next event (server queue only).
    private var waiters: [(c: NWConnection, after: Int, keepAlive: Bool, timeout: DispatchWorkItem)] = []
    /// Failed sign-ins per address: (count in the current minute, minute start, blocked until).
    private var failures: [String: (n: Int, since: Date, blockedUntil: Date?)] = [:]
    /// Requests from phones that aren't settled yet: track id → last status sent (main actor).
    @MainActor private var requests: [String: String] = [:]

    var token: String {
        if let t = UserDefaults.standard.string(forKey: "phoneSyncToken") { return t }
        let t = Self.newToken()
        UserDefaults.standard.set(t, forKey: "phoneSyncToken")
        return t
    }

    /// HMAC key shared only with the account service, which signs tickets for this Mac's phones with it.
    static var ticketSecret: String {
        if let s = UserDefaults.standard.string(forKey: "ticketSecret") { return s }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let s = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(s, forKey: "ticketSecret")
        return s
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

    // MARK: keeping up with the library

    /// Keeps the crate and request statuses current while sharing, whichever page the app shows.
    @MainActor func attach(_ store: LibraryStore) {
        self.store = store
        cancellables = []
        store.$state.debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.libraryChanged() }.store(in: &cancellables)
        store.$soulseek.sink { [weak self] _ in DispatchQueue.main.async { self?.updateRequests() } }.store(in: &cancellables)
        // While phones wait on requests, look at the downloader's progress every few seconds.
        Timer.publish(every: 5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self, self.running, !self.requests.isEmpty else { return }
                self.store?.refreshSoulseek()
            }.store(in: &cancellables)
    }

    @MainActor private func libraryChanged() {
        guard running else { return }
        refreshCrate()
        updateRequests()
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
        let snapshot = c.mapValues { (path: $0.0, analysis: $0.1) }
        queue.async {
            let old = self.crate
            self.crate = snapshot
            let added = snapshot.keys.filter { old[$0] == nil }
            let removed = old.keys.filter { snapshot[$0] == nil }
            guard !old.isEmpty || !snapshot.isEmpty, !added.isEmpty || !removed.isEmpty else { return }
            self.broadcast("crate", ["added": added.compactMap { self.crateItem($0) }, "removed": removed, "count": snapshot.count])
        }
    }

    /// Sends status changes of the phones' requests; settled ones are forgotten after they're sent.
    @MainActor private func updateRequests() {
        guard let store, !requests.isEmpty else { return }
        for (id, last) in requests {
            let now = store.requestStatus(id)
            guard now != last else { continue }
            requests[id] = now == "ready" ? nil : now
            broadcastFromMain("request", ["id": id, "status": now, "title": store.describe(id)])
        }
    }

    @MainActor private func broadcastFromMain(_ event: String, _ obj: [String: Any]) {
        queue.async { self.broadcast(event, obj) }
    }

    // MARK: start / stop

    @MainActor func start() {
        guard listener == nil else { return }
        refreshCrate()
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
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
        queue.async {
            self.waiters.forEach { $0.timeout.cancel(); $0.c.cancel() }
            self.waiters = []
        }
    }

    // MARK: HTTP

    private struct Request {
        var method: String
        var url: URLComponents
        var headers: [String: String]
        var body: Data
        var keepAlive: Bool
        var path: String { url.path }
        func query(_ name: String) -> String? { url.queryItems?.first { $0.name == name }?.value }
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        readRequest(c, buffer: Data())
    }

    /// Reads one request (head + body); idle keep-alive connections are closed after 60 s.
    private func readRequest(_ c: NWConnection, buffer: Data) {
        let idle = DispatchWorkItem { c.cancel() }
        queue.asyncAfter(deadline: .now() + 60, execute: idle)
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, err in
            idle.cancel()
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for l in lines.dropFirst() {
                    if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) }
                }
                let length = min(Int(headers["content-length"] ?? "") ?? 0, 1_048_576)
                let have = buf.count - end.upperBound
                if have < length {
                    if done || err != nil { c.cancel() } else { self.readRequest(c, buffer: buf) }
                    return
                }
                let parts = (lines.first ?? "").split(separator: " ")
                guard parts.count >= 3, let url = URLComponents(string: "http://x" + parts[1]) else {
                    return self.send(c, status: "400 Bad Request", body: Data("bad request".utf8), keepAlive: false)
                }
                let keep = parts[2] == "HTTP/1.1" && headers["connection"]?.lowercased() != "close"
                let body = buf.subdata(in: end.upperBound..<(end.upperBound + length))
                self.respond(c, Request(method: String(parts[0]), url: url, headers: headers, body: body, keepAlive: keep), peer: Self.peer(c))
            } else if done || err != nil || buf.count > 65_536 {
                c.cancel()
            } else {
                self.readRequest(c, buffer: buf)
            }
        }
    }

    private static func peer(_ c: NWConnection) -> String {
        if case let .hostPort(host, _) = c.endpoint { return "\(host)" }
        return "?"
    }

    // MARK: who's asking

    private enum Auth { case ok, denied, blocked }

    private func authorize(_ req: Request, peer: String) -> Auth {
        // Through the tunnel every connection comes from cloudflared on this Mac; Cloudflare says who it really is.
        let who = req.headers["cf-connecting-ip"] ?? peer
        let now = Date()
        if let until = failures[who]?.blockedUntil, until > now { return .blocked }
        let auth = req.headers["authorization"] ?? ""
        let given = auth.lowercased().hasPrefix("bearer ") ? String(auth.dropFirst(7)) : (req.headers["x-wreckbox-token"] ?? "")
        if !given.isEmpty && (Self.equal(given, token) || Self.validTicket(given)) {
            failures[who] = nil
            return .ok
        }
        var f = failures[who] ?? (0, now, nil)
        if now.timeIntervalSince(f.since) > 60 { f = (0, now, nil) }
        f.n += 1
        if f.n >= 10 { f.blockedUntil = now.addingTimeInterval(600) }
        failures[who] = f
        if failures.count > 1000 { failures = failures.filter { $0.value.blockedUntil ?? .distantPast > now } }
        return .denied
    }

    /// wbt1.<base64url "user.device.expiry">.<hex HMAC-SHA256 with this Mac's ticket secret>
    static func validTicket(_ t: String) -> Bool {
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "wbt1" else { return false }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let payloadData = Data(base64Encoded: b64), let payload = String(data: payloadData, encoding: .utf8) else { return false }
        let fields = payload.split(separator: ".")
        guard fields.count == 3, String(fields[1]) == AccountAPI.deviceID, let exp = TimeInterval(fields[2]),
              exp > Date().timeIntervalSince1970 else { return false }
        return equal(hmacHex(key: ticketSecret, payload), String(parts[2]))
    }

    static func hmacHex(key hexKey: String, _ msg: String) -> String {
        var key = [UInt8]()
        var i = hexKey.startIndex
        while i < hexKey.endIndex, let j = hexKey.index(i, offsetBy: 2, limitedBy: hexKey.endIndex) {
            key.append(UInt8(hexKey[i..<j], radix: 16) ?? 0)
            i = j
        }
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let m = Array(msg.utf8)
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), key, key.count, m, m.count, &mac)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison, so response timing doesn't reveal how much of a guess was right.
    static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var d: UInt8 = 0
        for i in 0..<x.count { d |= x[i] ^ y[i] }
        return d == 0
    }

    // MARK: routes

    private func respond(_ c: NWConnection, _ req: Request, peer: String) {
        switch authorize(req, peer: peer) {
        case .blocked: return send(c, status: "429 Too Many Requests", body: Data("too many attempts".utf8), keepAlive: false)
        case .denied: return send(c, status: "403 Forbidden", body: Data("not paired".utf8), keepAlive: req.keepAlive)
        case .ok: break
        }
        let path = req.path
        switch (req.method, path) {
        case ("GET", "/info"):
            return sendJSON(c, ["name": "WreckBox on \(Host.current().localizedName ?? "Mac")", "tracks": crate.count,
                                "lan": Self.localAddresses(), "port": Int(Self.port), "qualities": StreamQuality.allCases.map(\.rawValue),
                                "poll": true], keepAlive: req.keepAlive)
        case ("GET", "/library.json"):
            let body = (try? Data(contentsOf: libraryRoot.appendingPathComponent("library.json"))) ?? Data()
            return send(c, status: "200 OK", type: "application/json", body: body, keepAlive: req.keepAlive)
        case ("GET", "/crate"):
            return sendJSON(c, crate.keys.compactMap { crateItem($0) }, keepAlive: req.keepAlive)
        case ("GET", "/poll"):
            return poll(c, after: Int(req.query("after") ?? "") ?? -1, keepAlive: req.keepAlive)
        case ("GET", "/requests"):
            DispatchQueue.main.async {
                let list = self.requests.map { ["id": $0.key, "status": $0.value] }
                self.queue.async { self.sendJSON(c, list, keepAlive: req.keepAlive) }
            }
            return
        case ("POST", "/prepare"):
            let j = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            let q = StreamQuality(param: j["q"] as? String)
            for id in ((j["ids"] as? [String]) ?? []).prefix(10) {
                guard let src = crate[id]?.path, Transcoder.needsCopy(src, q) else { continue }
                DispatchQueue.main.async { Transcoder.shared.make(id, source: src, q, tag: self.store?.tagJob(id)) }
            }
            return sendJSON(c, ["ok": true], keepAlive: req.keepAlive)
        case ("POST", "/request"):
            let j = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                let id = self.request(id: j["id"] as? String, artist: j["artist"] as? String, title: j["title"] as? String, query: j["query"] as? String)
                let status = id.map { self.store?.requestStatus($0) ?? "searching" }
                self.queue.async {
                    if let id, let status {
                        self.sendJSON(c, ["ok": true, "id": id, "status": status], keepAlive: req.keepAlive)
                    } else {
                        self.send(c, status: "400 Bad Request", type: "application/json", body: Data(#"{"error":"Send a track id, or an artist and title."}"#.utf8), keepAlive: req.keepAlive)
                    }
                }
            }
            return
        default: break
        }
        if req.method == "GET", path.hasPrefix("/art/") {
            let id = String(path.dropFirst(5)).removingPercentEncoding ?? ""
            let f = ArtworkLoader.dir.appendingPathComponent(ArtworkLoader.fileStem(id) + ".jpg")
            guard let data = try? Data(contentsOf: f) else { return send(c, status: "404 Not Found", body: Data(), keepAlive: req.keepAlive) }
            return send(c, status: "200 OK", type: "image/jpeg", body: data, keepAlive: req.keepAlive)
        }
        if req.method == "GET", path.hasPrefix("/file/") {
            let id = String(path.dropFirst(6)).removingPercentEncoding ?? ""
            guard let original = crate[id]?.path else { return send(c, status: "404 Not Found", body: Data("no such track".utf8), keepAlive: req.keepAlive) }
            let q = StreamQuality(param: req.query("q"))
            guard Transcoder.needsCopy(original, q) else { return sendFile(c, original, req) }
            if let ready = Transcoder.shared.ready(id, source: original, q) {
                Transcoder.shared.touch(ready)
                return sendFile(c, ready.path, req)
            }
            // Not made yet: make it (usually 1–2 s); if that takes too long, play the original this time.
            DispatchQueue.main.async {
                let tag = self.store?.tagJob(id)
                DispatchQueue.global(qos: .userInitiated).async {
                    let copy = Transcoder.shared.wait(id, source: original, q, tag: tag, timeout: 4)
                    self.queue.async { self.sendFile(c, copy?.path ?? original, req) }
                }
            }
            return
        }
        send(c, status: "404 Not Found", body: Data(), keepAlive: req.keepAlive)
    }

    @MainActor private func request(id: String?, artist: String?, title: String?, query: String?) -> String? {
        guard let store, let tid = store.phoneRequest(id: id, artist: artist, title: title, query: query) else { return nil }
        let status = store.requestStatus(tid)
        if status != "ready" { requests[tid] = status }
        return tid
    }

    /// Requests the phone queued in the account while this Mac was offline.
    @MainActor func takeQueued(_ list: [[String: Any]]) {
        for r in list {
            _ = request(id: r["id"] as? String, artist: r["artist"] as? String, title: r["title"] as? String, query: r["query"] as? String)
        }
    }

    private func crateItem(_ id: String) -> [String: Any]? {
        guard let v = crate[id] else { return nil }
        let size = ((try? FileManager.default.attributesOfItem(atPath: v.path)[.size]) as? NSNumber)?.intValue ?? 0
        var item: [String: Any] = ["id": id, "ext": "." + (v.path as NSString).pathExtension.lowercased(), "size": size]
        if let a = v.analysis, let j = try? JSONSerialization.jsonObject(with: a) { item["analysis"] = j }
        return item
    }

    // MARK: live events

    private func poll(_ c: NWConnection, after: Int, keepAlive: Bool) {
        // First call (-1), or this Mac restarted since (its numbers start again): just say where things are.
        if after < 0 || after > seq {
            return sendJSON(c, ["seq": seq, "events": [Any](), "reset": after > seq], keepAlive: keepAlive)
        }
        if events.last.map({ $0.seq > after }) == true {
            return answer(c, after: after, keepAlive: keepAlive)
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.waiters.removeAll { $0.c === c }
            self.answer(c, after: after, keepAlive: keepAlive)
        }
        waiters.append((c, after, keepAlive, timeout))
        queue.asyncAfter(deadline: .now() + 25, execute: timeout)
    }

    private func answer(_ c: NWConnection, after: Int, keepAlive: Bool) {
        let oldest = events.first?.seq ?? seq + 1
        let missed = after + 1 < oldest && after < seq   // too far behind: the phone reloads everything
        let list = events.filter { $0.seq > after }.map { ["seq": $0.seq, "event": $0.name, "data": $0.data] }
        sendJSON(c, ["seq": seq, "events": list, "reset": missed], keepAlive: keepAlive)
    }

    /// Developer test (djlib phone-serve): a harmless event phones ignore.
    func testEvent() { queue.async { self.broadcast("test", ["t": Int(Date().timeIntervalSince1970)]) } }

    /// Server queue only: records the event and wakes every waiting phone.
    private func broadcast(_ event: String, _ obj: Any) {
        seq += 1
        events.append((seq, event, obj))
        if events.count > 200 { events.removeFirst(events.count - 200) }
        let ready = waiters
        waiters = []
        for w in ready {
            w.timeout.cancel()
            answer(w.c, after: w.after, keepAlive: w.keepAlive)
        }
    }

    // MARK: sending


    private func sendFile(_ c: NWConnection, _ file: String, _ req: Request) {
        guard let h = FileHandle(forReadingAtPath: file) else { return send(c, status: "404 Not Found", body: Data(), keepAlive: req.keepAlive) }
        let len = ((try? FileManager.default.attributesOfItem(atPath: file)[.size]) as? NSNumber)?.intValue ?? 0
        var start = 0, end = len - 1, status = "200 OK"
        var extra = "Accept-Ranges: bytes\r\n"
        if let r = req.headers["range"], let m = r.range(of: #"bytes=(\d*)-(\d*)"#, options: .regularExpression) {
            let spec = r[m].dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            let a = Int(spec.first ?? ""), b = spec.count > 1 ? Int(spec[1]) : nil
            if let a { start = a; end = min(b ?? len - 1, len - 1) } else if let b { start = max(0, len - b) }
            guard start <= end else {
                try? h.close()
                return send(c, status: "416 Range Not Satisfiable", body: Data(), keepAlive: req.keepAlive)
            }
            status = "206 Partial Content"
            extra += "Content-Range: bytes \(start)-\(end)/\(len)\r\n"
        }
        let conn = req.keepAlive ? "keep-alive" : "close"
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(Self.mime(file))\r\nContent-Length: \(end - start + 1)\r\n\(extra)Cache-Control: private, max-age=86400\r\nConnection: \(conn)\r\n\r\n"
        try? h.seek(toOffset: UInt64(start))
        c.send(content: Data(header.utf8), completion: .contentProcessed { _ in self.stream(c, h, remaining: end - start + 1, keepAlive: req.keepAlive) })
    }

    /// Sends the file in 256 KB chunks, one after another, so large FLACs don't sit in memory.
    private func stream(_ c: NWConnection, _ h: FileHandle, remaining: Int, keepAlive: Bool) {
        guard remaining > 0, let chunk = try? h.read(upToCount: min(262_144, remaining)), !chunk.isEmpty else {
            try? h.close()
            finish(c, keepAlive: keepAlive)
            return
        }
        c.send(content: chunk, completion: .contentProcessed { [weak self] err in
            if err != nil { try? h.close(); c.cancel(); return }
            self?.stream(c, h, remaining: remaining - chunk.count, keepAlive: keepAlive)
        })
    }

    private func sendJSON(_ c: NWConnection, _ obj: Any, keepAlive: Bool) {
        let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("null".utf8)
        send(c, status: "200 OK", type: "application/json", body: body, keepAlive: keepAlive)
    }

    private func send(_ c: NWConnection, status: String, type: String = "text/plain", body: Data, keepAlive: Bool) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in self?.finish(c, keepAlive: keepAlive) })
    }

    /// After a response: wait for the next request on the same connection, or close it.
    private func finish(_ c: NWConnection, keepAlive: Bool) {
        if keepAlive {
            readRequest(c, buffer: Data())
        } else {
            c.send(content: nil, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
        }
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
            AccountPanel().frame(maxWidth: 640, alignment: .leading)
            Spacer()
        }
        .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 10)
        .onReceive(store.$state) { _ in if server.running { server.refreshCrate() } }
    }
}
