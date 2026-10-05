import CommonCrypto
import Foundation
import SwiftUI

// WreckBox account for the Mac app — same service and password scheme as the phone / Windows apps:
// the password becomes a PBKDF2-HMAC-SHA256 key (200,000 rounds, salted with the email) on this Mac; only the
// key is sent. The Mac uploads its library + a per-track summary, and (with "Use from anywhere") its tunnel address.

enum AccountAPI {
    static let base = URL(string: "https://wreckbox-api.moloyb301.workers.dev")!

    static var token: String? {
        get { UserDefaults.standard.string(forKey: "accountToken") }
        set { UserDefaults.standard.set(newValue, forKey: "accountToken") }
    }
    static var email: String? {
        get { UserDefaults.standard.string(forKey: "accountEmail") }
        set { UserDefaults.standard.set(newValue, forKey: "accountEmail") }
    }
    static var signedIn: Bool { token != nil }

    static var deviceID: String {
        if let d = UserDefaults.standard.string(forKey: "accountDeviceID") { return d }
        let d = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
        UserDefaults.standard.set(String(d), forKey: "accountDeviceID")
        return String(d)
    }

    static func deriveKey(email: String, password: String) -> String {
        let salt = Array("wreckbox:\(email.trimmingCharacters(in: .whitespaces).lowercased())".utf8)
        var out = [UInt8](repeating: 0, count: 32)
        _ = password.withCString { pw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, strlen(pw), salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000, &out, out.count)
        }
        return out.map { String(format: "%02x", $0) }.joined()
    }

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    @discardableResult
    static func call(_ method: String, _ path: String, body: Data? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(deviceID, forHTTPHeaderField: "x-wreckbox-device")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if code == 401 && path != "v1/login" { token = nil }
        guard code < 400 else { throw Failure(message: json["error"] as? String ?? "Account service error \(code)") }
        return json
    }

    static func jsonBody(_ o: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data() }

    static func signIn(email: String, password: String, create: Bool, name: String = "") async throws {
        if create && password.count < 8 { throw Failure(message: "Use at least 8 characters for the password.") }
        let key = await Task.detached { deriveKey(email: email, password: password) }.value
        let j = try await call("POST", create ? "v1/signup" : "v1/login",
                               body: jsonBody(["email": email.trimmingCharacters(in: .whitespaces), "key": key, "name": name]))
        token = j["token"] as? String
        Self.email = (j["user"] as? [String: Any])?["email"] as? String
    }

    static func signOut() async {
        _ = try? await call("POST", "v1/logout")
        token = nil
    }

    /// Library + per-track summary (status, BPM, key, energy) — what the account's phones show. No file paths.
    @MainActor static func uploadLibrary(_ store: LibraryStore) async throws {
        guard signedIn, let lib = try? Data(contentsOf: libraryRoot.appendingPathComponent("library.json")) else { return }
        try await call("PUT", "v1/blob/library", body: lib)
        var tracks: [String: Any] = [:]
        for t in store.library?.tracks ?? [] {
            guard let st = store.state.tracks[t.id] else { continue }
            var e: [String: Any] = ["s": st.status.rawValue]
            if let p = st.localPath, let a = store.analysis[p] {
                if let b = a.bpm { e["bpm"] = b }
                if let c = a.camelot { e["camelot"] = c }
                if let k = a.key { e["key"] = k }
                if let en = a.energy { e["energy"] = en }
            }
            tracks[t.id] = e
        }
        try await call("PUT", "v1/blob/state", body: jsonBody(["tracks": tracks, "from": deviceID, "at": ISO8601DateFormatter().string(from: Date())]))
    }

    static func registerComputer(url: String?, syncToken: String?) async throws {
        var body: [String: Any] = ["id": deviceID, "name": "WreckBox on \(Host.current().localizedName ?? "Mac")", "platform": "macos"]
        if let url { body["url"] = url }
        if let syncToken { body["syncToken"] = syncToken }
        try await call("POST", "v1/devices", body: jsonBody(body))
    }
}

/// "Use from anywhere": keeps a Cloudflare quick tunnel to the phone-sync server and registers its address.
@MainActor
final class RemoteAccess: ObservableObject {
    @Published var status = "Off"
    @Published var url: String?
    @Published var signedIn = AccountAPI.signedIn
    private var proc: Process?
    private var heartbeat: Timer?
    private var wanted = false
    weak var server: PhoneSyncServer?
    weak var store: LibraryStore?

    static var binary: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WreckBox/cloudflared")
    }

    var enabled: Bool { UserDefaults.standard.bool(forKey: "useFromAnywhere") }

    /// Restores "Use from anywhere" after a restart.
    func resume() { if enabled && AccountAPI.signedIn { start() } }

    func start() {
        wanted = true
        UserDefaults.standard.set(true, forKey: "useFromAnywhere")
        guard proc == nil else { return }
        guard AccountAPI.signedIn else { status = "Sign in to your WreckBox account first."; return }
        server?.start()
        Task {
            do {
                try await ensureBinary()
                status = "Connecting…"
                let p = Process()
                p.executableURL = Self.binary
                p.arguments = ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:\(PhoneSyncServer.port)"]
                let pipe = Pipe()
                p.standardError = pipe
                p.standardOutput = pipe
                pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                    let text = String(decoding: h.availableData, as: UTF8.self)
                    guard let r = text.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#, options: .regularExpression) else { return }
                    let found = String(text[r])
                    Task { @MainActor in
                        guard let self, self.url == nil else { return }
                        self.url = found
                        await self.registerNow()
                        self.status = "Reachable from anywhere"
                    }
                }
                p.terminationHandler = { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.proc = nil
                        self.url = nil
                        self.heartbeat?.invalidate()
                        self.status = self.wanted ? "Reconnecting…" : "Off"
                        if self.wanted { try? await Task.sleep(for: .seconds(10)); if self.wanted { self.start() } }
                    }
                }
                try p.run()
                proc = p
                heartbeat?.invalidate()
                heartbeat = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { @MainActor in await self?.registerNow() } }
            } catch {
                status = "Couldn't connect: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        wanted = false
        UserDefaults.standard.set(false, forKey: "useFromAnywhere")
        heartbeat?.invalidate()
        proc?.terminate()
        proc = nil
        url = nil
        status = "Off"
        Task { try? await AccountAPI.registerComputer(url: nil, syncToken: nil) } // no longer reachable
    }

    /// Re-registers the address (keeps "online") and refreshes the library copy in the account.
    func registerNow() async {
        guard let url else { return }
        server?.refreshCrate()
        do {
            try await AccountAPI.registerComputer(url: url, syncToken: server?.token)
            if let store { try await AccountAPI.uploadLibrary(store) }
        } catch {
            status = "Account: \(error.localizedDescription)"
            signedIn = AccountAPI.signedIn
        }
    }

    private func ensureBinary() async throws {
        if FileManager.default.isExecutableFile(atPath: Self.binary.path) { return }
        status = "Downloading Cloudflare tunnel tool…"
        let dir = Self.binary.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (tmp, resp) = try await URLSession.shared.download(from: URL(string: "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64.tgz")!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw AccountAPI.Failure(message: "download failed") }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", tmp.path, "-C", dir.path]
        try tar.run()
        tar.waitUntilExit()
        guard FileManager.default.isExecutableFile(atPath: Self.binary.path) else { throw AccountAPI.Failure(message: "unpack failed") }
    }
}

/// Sign-in / sign-up and the "Use from anywhere" switch (shown on the Sync to phone page).
struct AccountPanel: View {
    @EnvironmentObject var remote: RemoteAccess
    @State private var email = AccountAPI.email ?? ""
    @State private var password = ""
    @State private var name = ""
    @State private var creating = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DotLabel("Use from anywhere", color: Theme.text)
            if remote.signedIn {
                Text("Signed in as \(AccountAPI.email ?? "")").font(Theme.ui(13, .semibold))
                Text("Your phone signs in to the same account and finds this Mac — at home or on mobile data — while this Mac is on and WreckBox is open.")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    PillButton(label: remote.url == nil ? "Turn on" : "Turn off", icon: remote.url == nil ? "globe" : "stop.fill",
                               style: remote.url == nil ? .smart : .glass) { remote.url == nil ? remote.start() : remote.stop() }
                    PillButton(label: "Sign out", icon: "rectangle.portrait.and.arrow.right") {
                        Task { remote.stop(); await AccountAPI.signOut(); remote.signedIn = false }
                    }
                }
                Text(remote.status).font(Theme.ui(12, .semibold)).foregroundStyle(remote.url != nil ? Theme.lilac : Theme.text2)
            } else {
                Text(creating ? "Create your WreckBox account" : "Sign in to your WreckBox account").font(Theme.ui(13, .semibold))
                if creating { TextField("Your name", text: $name).textFieldStyle(.roundedBorder) }
                TextField("Email", text: $email).textFieldStyle(.roundedBorder)
                SecureField("Password (8+ characters)", text: $password).textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    PillButton(label: busy ? "Please wait…" : (creating ? "Create account" : "Sign in"), icon: "person.crop.circle", style: .primary) {
                        guard !busy else { return }
                        busy = true
                        message = nil
                        Task {
                            do {
                                try await AccountAPI.signIn(email: email, password: password, create: creating, name: name)
                                password = ""
                                remote.signedIn = true
                            } catch {
                                message = error.localizedDescription
                            }
                            busy = false
                        }
                    }
                    Button(creating ? "I have an account" : "Create an account") { creating.toggle() }
                        .buttonStyle(.plain).font(Theme.ui(12.5, .semibold)).foregroundStyle(Theme.text2)
                }
                if let message { Text(message).font(Theme.ui(12.5, .semibold)).foregroundStyle(Theme.peach) }
            }
        }
        .padding(18)
        .smartGlass(Theme.Radius.tile)
    }
}
