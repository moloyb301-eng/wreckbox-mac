import AuthenticationServices
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
    /// Google sign-in needs a Google OAuth client on the account service; off until one is set up.
    static let googleEnabled = false

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

    /// Registers this Mac with its tunnel address (nil = not reachable) and the secret the account service signs
    /// phones' tickets with. Phones never receive the secret or the pairing token.
    static func registerComputer(url: String?) async throws {
        var body: [String: Any] = ["id": deviceID, "name": "WreckBox on \(Host.current().localizedName ?? "Mac")", "platform": "macos",
                                   "ticketSecret": PhoneSyncServer.ticketSecret]
        if let url { body["url"] = url }
        try await call("POST", "v1/devices", body: jsonBody(body))
    }

    /// A one-time code (10 min) that signs a phone in to this account when it scans the QR code.
    static func startLink() async throws -> String {
        let j = try await call("POST", "v1/link/start")
        guard let code = j["code"] as? String else { throw Failure(message: "Couldn't make a sign-in code.") }
        return code
    }

    /// Requests phones queued in the account while this Mac was offline (handed out once).
    static func takeQueuedRequests() async throws -> [[String: Any]] {
        var c = URLComponents(url: base.appendingPathComponent("v1/requests"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "device", value: deviceID)]
        var req = URLRequest(url: c.url!)
        req.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["requests"] as? [[String: Any]] ?? []
    }

    // MARK: Sign in with Google

    /// Google sign-in runs on the account service; this Mac only sees a one-time code, which it swaps for a session
    /// together with a secret (PKCE) that never left the Mac.
    @MainActor static func signInWithGoogle() async throws {
        var raw = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw)
        let verifier = b64url(Data(raw))
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let v = Array(verifier.utf8)
        CC_SHA256(v, CC_LONG(v.count), &digest)
        var start = URLComponents(url: base.appendingPathComponent("v1/auth/google/start"), resolvingAgainstBaseURL: false)!
        start.queryItems = [URLQueryItem(name: "redirect", value: "wreckbox://auth"), URLQueryItem(name: "challenge", value: b64url(Data(digest)))]
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: start.url!, callbackURLScheme: "wreckbox") { url, error in
                if let url { cont.resume(returning: url) } else { cont.resume(throwing: error ?? Failure(message: "Sign-in cancelled.")) }
            }
            session.presentationContextProvider = WebAuthAnchor.shared
            session.prefersEphemeralWebBrowserSession = false
            WebAuthAnchor.shared.session = session   // must stay alive until the sheet closes
            if !session.start() { cont.resume(throwing: Failure(message: "Couldn't open the sign-in window.")) }
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let e = items.first(where: { $0.name == "error" })?.value {
            throw Failure(message: e == "cancelled" || e == "access_denied" ? "Sign-in cancelled." : "Google sign-in failed (\(e)).")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw Failure(message: "Google sign-in failed.") }
        let j = try await call("POST", "v1/auth/exchange", body: jsonBody(["code": code, "verifier": verifier]))
        token = j["token"] as? String
        email = (j["user"] as? [String: Any])?["email"] as? String
    }

    static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// "Use from anywhere": keeps a Cloudflare quick tunnel to the phone-sync server and registers its address.
@MainActor
final class RemoteAccess: ObservableObject {
    @Published var status = "Off" { didSet { Self.log(status) } }

    /// "Use from anywhere" events, for diagnosing connection problems: ~/Library/Logs/WreckBox.log
    nonisolated static func log(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WreckBox.log")
        let text = "\(ISO8601DateFormatter().string(from: Date())) remote: \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
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
    func resume() {
        Self.log("resume: enabled=\(enabled) signedIn=\(AccountAPI.signedIn)")
        if enabled && AccountAPI.signedIn { start() }
    }

    func start() {
        wanted = true
        UserDefaults.standard.set(true, forKey: "useFromAnywhere")
        guard proc == nil else { return }
        guard AccountAPI.signedIn else { status = "Sign in to your WreckBox account first."; return }
        server?.start()
        Task {
            do {
                try await ensureBinary()
                // A tunnel left behind by an earlier run (e.g. the app was force-quit) would keep an old address alive.
                let stale = Process()
                stale.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                stale.arguments = ["-f", Self.binary.path]
                try? stale.run()
                stale.waitUntilExit()
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
        Task { try? await AccountAPI.registerComputer(url: nil) } // no longer reachable
    }

    /// Re-registers the address (keeps "online") and refreshes the library copy in the account.
    func registerNow() async {
        guard let url else { return }
        server?.refreshCrate()
        do {
            try await AccountAPI.registerComputer(url: url)
            if let store { try await AccountAPI.uploadLibrary(store) }
            if let queued = try? await AccountAPI.takeQueuedRequests(), !queued.isEmpty { server?.takeQueued(queued) }
            // Shares revoked anywhere stop working here within one heartbeat.
            if let j = try? await AccountAPI.call("GET", "v1/shares") {
                let revoked = (j["shares"] as? [[String: Any]] ?? []).filter { ($0["revoked"] as? Int ?? 0) != 0 }.compactMap { $0["id"] as? String }
                PhoneSyncServer.revokedShares.formUnion(revoked)
            }
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
                    if AccountAPI.googleEnabled {
                        PillButton(label: "Continue with Google", icon: "g.circle", style: .glass) {
                            guard !busy else { return }
                            busy = true
                            message = nil
                            Task {
                                do {
                                    try await AccountAPI.signInWithGoogle()
                                    remote.signedIn = true
                                } catch {
                                    if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin { message = error.localizedDescription }
                                }
                                busy = false
                            }
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

/// Window the Google sign-in sheet attaches to.
final class WebAuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthAnchor()
    var session: ASWebAuthenticationSession?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
