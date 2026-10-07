import AppKit
import SwiftUI

// Sharing music with friends, both ways.
//
// Out: "Share" makes a key (WBX-XXXXX-XXXXX-XXXXX) and a link for the whole library or one playlist. The account
// service keeps only the key's hash; when a friend opens it, the service hands them this Mac's address and a 6-hour
// ticket signed with this Mac's own secret, and the phone-sync server lets that ticket do only what the share
// covers: list it, stream it, download it (PhoneSync.respondGuest). Revoking stops it at once.
//
// In: a friend's key / link (pasted, or a wreckbox://share link) adds their library or playlist here. Play streams
// it through this Mac's player (each track is fetched into _cache/friends first); Download puts a copy in your
// library, filed and tagged like any other download.

struct FriendShare: Codable, Identifiable, Equatable {
    var id: String
    var key: String
    var kind: String
    var playlist: String?
    var owner: String
    var computer: String
    var url: String?
    var ticket: String?
    var expires: Double     // ms since 1970
    var online = false

    var title: String { kind == "playlist" ? (playlist ?? "Playlist") : "\(owner)'s library" }
}

struct FriendTrack: Identifiable {
    let track: LibraryTrack
    let ext: String
    let quality: String?
    var id: String { track.id }
}

@MainActor
final class FriendShares: ObservableObject {
    static let shared = FriendShares()

    @Published private(set) var shares: [FriendShare] = []
    @Published var tracks: [String: [FriendTrack]] = [:]     // share id → its tracks
    @Published var status: [String: String] = [:]           // share id → "Loading…" / error
    @Published var jobs: [String: String] = [:]             // track id → "fetching" / "downloading" / "done" / error
    private var owner: [String: String] = [:]               // track id → share id

    static let cacheDir = libraryRoot.appendingPathComponent("_cache/friends")
    private static let storeKey = "friendShares"

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.storeKey), let s = try? JSONDecoder().decode([FriendShare].self, from: d) { shares = s }
        Self.prune()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(shares) { UserDefaults.standard.set(d, forKey: Self.storeKey) }
    }

    // MARK: keys

    /// A key, a share link, or a wreckbox://share?key= link → the key.
    static func key(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let r = t.range(of: #"WBX-[0-9A-Z]{5}-[0-9A-Z]{5}-[0-9A-Z]{5}"#, options: .regularExpression) else { return nil }
        return String(t[r])
    }

    /// Asks the account service what the key opens (and for a fresh ticket).
    private func open(_ key: String) async throws -> FriendShare {
        var req = URLRequest(url: AccountAPI.base.appendingPathComponent("v1/shares/open"))
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = AccountAPI.jsonBody(["key": key])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let id = j["id"] as? String else {
            throw AccountAPI.Failure(message: j["error"] as? String ?? "Couldn't open that key.")
        }
        return FriendShare(id: id, key: key, kind: j["kind"] as? String ?? "library", playlist: j["playlist"] as? String,
                           owner: j["owner"] as? String ?? "A friend", computer: j["computer"] as? String ?? "",
                           url: j["url"] as? String, ticket: j["ticket"] as? String,
                           expires: j["expires"] as? Double ?? 0, online: j["online"] as? Bool ?? false)
    }

    func add(_ text: String) async throws {
        guard let key = Self.key(from: text) else { throw AccountAPI.Failure(message: "That doesn't look like a WreckBox key (WBX-…).") }
        let s = try await open(key)
        shares.removeAll { $0.id == s.id }
        shares.insert(s, at: 0)
        save()
        await load(s.id)
    }

    func remove(_ id: String) {
        shares.removeAll { $0.id == id }
        tracks[id] = nil
        save()
    }

    /// A share with a ticket good for at least 10 more minutes (reopened with its key when needed).
    private func fresh(_ id: String) async throws -> FriendShare {
        guard let i = shares.firstIndex(where: { $0.id == id }) else { throw AccountAPI.Failure(message: "Not added") }
        if shares[i].ticket != nil, shares[i].url != nil, shares[i].expires > Date().timeIntervalSince1970 * 1000 + 600_000 { return shares[i] }
        let s = try await open(shares[i].key)
        if let j = shares.firstIndex(where: { $0.id == id }) { shares[j] = s }
        save()
        return s
    }

    private func get(_ s: FriendShare, _ path: String) async throws -> Data {
        guard let base = s.url, let url = URL(string: base + path) else { throw AccountAPI.Failure(message: "\(s.owner)'s computer is offline.") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("Bearer \(s.ticket ?? "")", forHTTPHeaderField: "authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 403 { throw AccountAPI.Failure(message: "\(s.owner) stopped sharing this.") }
        guard code == 200 else { throw AccountAPI.Failure(message: "\(s.owner)'s computer didn't answer (\(code)).") }
        return data
    }

    // MARK: browsing

    private struct Lib: Decodable { let tracks: [LibraryTrack]; let playlists: [LibraryPlaylist] }
    private struct CrateItem: Decodable { let id: String; let ext: String; let quality: String? }

    func load(_ id: String) async {
        status[id] = "Loading…"
        do {
            let s = try await fresh(id)
            let lib = try JSONDecoder().decode(Lib.self, from: try await get(s, "/library.json"))
            let crate = try JSONDecoder().decode([CrateItem].self, from: try await get(s, "/crate"))
            let files = Dictionary(crate.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let order = lib.playlists.first.map { $0.trackIDs } ?? lib.tracks.map(\.id)
            let byID = Dictionary(lib.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let ids = s.kind == "playlist" ? order : lib.tracks.sorted { ($0.firstAdded ?? "") > ($1.firstAdded ?? "") }.map(\.id)
            tracks[id] = ids.compactMap { tid in
                guard let t = byID[tid], let f = files[tid] else { return nil }
                return FriendTrack(track: t, ext: f.ext, quality: f.quality)
            }
            for t in tracks[id] ?? [] { owner[t.id] = id }
            status[id] = nil
        } catch {
            status[id] = error.localizedDescription
        }
    }

    // MARK: playing (used by Playback and LibraryStore for tracks that aren't in your library)

    func track(_ id: String) -> LibraryTrack? {
        guard let s = owner[id] else { return nil }
        return tracks[s]?.first { $0.id == id }?.track
    }

    func has(_ id: String) -> Bool { owner[id] != nil }

    private func cacheFile(_ id: String) -> URL? {
        guard let s = owner[id], let t = tracks[s]?.first(where: { $0.id == id }) else { return nil }
        return Self.cacheDir.appendingPathComponent(safeFileName("\(s)-\(id)") + t.ext)
    }

    func cachedPath(_ id: String) -> String? {
        guard let f = cacheFile(id), FileManager.default.fileExists(atPath: f.path) else { return nil }
        return f.path
    }

    /// Fetches the whole file (original quality) into the cache.
    func fetch(_ id: String) async -> String? {
        if let p = cachedPath(id) { return p }
        guard let sid = owner[id], let dest = cacheFile(id) else { return nil }
        if jobs[id] == nil { jobs[id] = "fetching" }
        defer { if jobs[id] == "fetching" { jobs[id] = nil } }
        do {
            let s = try await fresh(sid)
            guard let base = s.url, let url = URL(string: base + "/file/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)) else {
                throw AccountAPI.Failure(message: "\(s.owner)'s computer is offline.")
            }
            var req = URLRequest(url: url)
            req.timeoutInterval = 60
            req.setValue("Bearer \(s.ticket ?? "")", forHTTPHeaderField: "authorization")
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw AccountAPI.Failure(message: "Couldn't fetch the track.") }
            try FileManager.default.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest.path
        } catch {
            jobs[id] = error.localizedDescription
            return nil
        }
    }

    func play(_ id: String, in share: String, shuffled: Bool = false) {
        let list = (tracks[share] ?? []).map(\.id)
        if shuffled { return Playback.shared.playShuffled(list) }
        Playback.shared.play(id, list: list)
    }

    /// A copy into your library, filed and tagged like any download.
    func download(_ id: String, store: LibraryStore) async {
        guard await DownloadGate.allow(), let t = track(id) else { return }
        jobs[id] = "downloading"
        guard let cached = await fetch(id) else { return }
        // Same song already in your library (same ISRC): that track gets the file; otherwise a new track in "From friends".
        let target = store.library?.tracks.contains { $0.id == id } == true
            ? id : store.addRequestedTrack(artist: t.artists.first ?? "Unknown", title: t.title, via: "friend")
        let dir = Self.cacheDir.appendingPathComponent("import", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(safeFileName(t.artists.joined(separator: ", ") + " - " + t.title) + (cached as NSString).pathExtension.prefixed)
        try? FileManager.default.removeItem(at: copy)
        do {
            try FileManager.default.copyItem(atPath: cached, toPath: copy.path)
            _ = await store.importDownloaded(copy, source: "friend", trackID: target)
            jobs[id] = "done"
        } catch {
            jobs[id] = error.localizedDescription
        }
    }

    /// Keeps the streaming cache under 3 GB, oldest first.
    private static func prune() {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey])) ?? [])
            .filter { !$0.hasDirectoryPath }
            .map { f -> (URL, Int, Date) in
                let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey])
                return (f, v?.fileSize ?? 0, v?.contentAccessDate ?? .distantPast)
            }
            .sorted { $0.2 < $1.2 }
        var total = files.reduce(0) { $0 + $1.1 }
        for f in files where total > 3 << 30 {
            try? fm.removeItem(at: f.0)
            total -= f.1
        }
    }
}

private extension String {
    var prefixed: String { isEmpty ? "" : "." + self }
}

// MARK: - Shares this Mac gives out

struct OwnShare: Identifiable {
    let id: String
    let kind: String
    let playlist: String?
    let label: String
    let created: Double
    let lastUsed: Double?
    let revoked: Bool
}

@MainActor
final class ShareManager: ObservableObject {
    @Published var shares: [OwnShare] = []
    @Published var made: (key: String, link: String)?
    @Published var message: String?
    @Published var busy = false

    func refresh() async {
        guard AccountAPI.signedIn else { return }
        do {
            let j = try await AccountAPI.call("GET", "v1/shares")
            let list = (j["shares"] as? [[String: Any]] ?? []).filter { ($0["computer"] as? String) == AccountAPI.deviceID }
            shares = list.map {
                OwnShare(id: $0["id"] as? String ?? "", kind: $0["kind"] as? String ?? "library", playlist: $0["playlist"] as? String,
                         label: $0["label"] as? String ?? "", created: $0["created"] as? Double ?? 0, lastUsed: $0["lastUsed"] as? Double,
                         revoked: ($0["revoked"] as? Int ?? 0) != 0)
            }
            // A share revoked anywhere (e.g. from another computer) stops here too.
            PhoneSyncServer.revokedShares.formUnion(shares.filter(\.revoked).map(\.id))
        } catch {
            message = error.localizedDescription
        }
    }

    func make(playlist: String?, label: String, days: Int) async {
        busy = true
        defer { busy = false }
        message = nil
        var body: [String: Any] = ["computer": AccountAPI.deviceID, "kind": playlist == nil ? "library" : "playlist", "label": label, "days": days]
        if let playlist { body["playlist"] = playlist }
        do {
            let j = try await AccountAPI.call("POST", "v1/shares", body: AccountAPI.jsonBody(body))
            if let k = j["key"] as? String, let l = j["link"] as? String { made = (k, l) }
            await refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    func revoke(_ id: String) async {
        PhoneSyncServer.revokedShares.insert(id)
        _ = try? await AccountAPI.call("DELETE", "v1/shares/\(id)")
        await refresh()
    }
}

// MARK: - The Friends page

struct FriendsView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var remote: RemoteAccess
    @ObservedObject var friends = FriendShares.shared
    @StateObject private var mine = ShareManager()
    @AppStorage("friendsTab") private var tab = "in"
    @State private var keyText = ""
    @State private var adding = false
    @State private var addError: String?
    @State private var selected: String?
    @State private var sharePlaylist = ""      // "" = whole library
    @State private var shareLabel = ""
    @State private var shareDays = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(eyebrow: "Library", title: "Friends", subtitle: "Stream and download from friends' libraries — and share yours with a key") {
                HStack(spacing: 8) {
                    PillButton(label: "From friends", icon: "person.2", style: tab == "in" ? .primary : .glass) { tab = "in" }
                    PillButton(label: "Share yours", icon: "key", style: tab == "out" ? .primary : .glass) { tab = "out" }
                }
            }
            if tab == "in" { incoming } else { outgoing }
        }
        .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 10)
        .task { await mine.refresh() }
    }

    // MARK: from friends

    private var incoming: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Paste a friend's key or link (WBX-…)", text: $keyText)
                    .textFieldStyle(.plain).font(Theme.ui(14))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.glassFill).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline)))
                    .onSubmit { addKey() }
                PillButton(label: adding ? "Opening…" : "Add", icon: "plus", style: .smart) { addKey() }.disabled(adding)
            }
            if let addError { Text(addError).font(Theme.ui(12.5)).foregroundStyle(Theme.peach) }
            if friends.shares.isEmpty {
                EmptyState(icon: "person.2", text: "When a friend shares their library or a playlist, paste their key here (or open their link) to stream and download it.")
                    .glass(Theme.Radius.card)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 2) {
                        ForEach(friends.shares) { s in shareRow(s) }
                        Spacer(minLength: 0)
                    }
                    .padding(6).frame(width: 250).frame(maxHeight: .infinity).glass(Theme.Radius.card)
                    trackList.frame(maxWidth: .infinity, maxHeight: .infinity).glass(Theme.Radius.card)
                }
            }
        }
        .onAppear { if selected == nil { selected = friends.shares.first?.id } }
        .task(id: selected) { if let s = selected, friends.tracks[s] == nil { await friends.load(s) } }
    }

    private func addKey() {
        guard !adding else { return }
        adding = true
        addError = nil
        Task {
            do {
                try await friends.add(keyText)
                keyText = ""
                selected = friends.shares.first?.id
            } catch {
                addError = error.localizedDescription
            }
            adding = false
        }
    }

    private func shareRow(_ s: FriendShare) -> some View {
        Button { selected = s.id } label: {
            HStack(spacing: 10) {
                Image(systemName: s.kind == "playlist" ? "music.note.list" : "music.note.house").frame(width: 18)
                    .foregroundStyle(selected == s.id ? Theme.lilac : Theme.text2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.title).font(Theme.ui(13, .semibold)).lineLimit(1)
                    Text(s.kind == "playlist" ? "from \(s.owner)" : s.computer).font(Theme.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(selected == s.id ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reload") { Task { await friends.load(s.id) } }
            Button("Remove") { friends.remove(s.id); if selected == s.id { selected = friends.shares.first?.id } }
        }
    }

    @ViewBuilder private var trackList: some View {
        if let sid = selected, let share = friends.shares.first(where: { $0.id == sid }) {
            let list = friends.tracks[sid] ?? []
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(share.title).font(Theme.ui(18, .semibold)).lineLimit(1)
                        Text(friends.status[sid] ?? "\(list.count) tracks · shared by \(share.owner)").font(Theme.ui(12))
                            .foregroundStyle(friends.status[sid] == nil || friends.status[sid] == "Loading…" ? Theme.text2 : Theme.peach)
                    }
                    Spacer()
                    if !list.isEmpty {
                        PillButton(label: "Play", icon: "play.fill", style: .primary) { friends.play(list[0].id, in: sid) }
                        PillButton(label: "Shuffle", icon: "shuffle") { friends.play(list[0].id, in: sid, shuffled: true) }
                    }
                    PillButton(label: "Reload", icon: "arrow.clockwise") { Task { await friends.load(sid) } }
                }
                .padding(14)
                Divider().overlay(Theme.hairline)
                Scroller {
                    LazyVStack(spacing: 2) {
                        ForEach(list) { t in friendRow(t, share: sid) }
                    }
                    .padding(6)
                }
            }
        } else {
            EmptyState(icon: "music.note.list", text: "Pick a friend's library or playlist.")
        }
    }

    private func friendRow(_ t: FriendTrack, share: String) -> some View {
        let playing = Playback.shared.active?.trackID == t.id
        return HStack(spacing: 12) {
            AsyncImage(url: t.track.artworkURL.flatMap(URL.init(string:))) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Theme.glassFill }
                .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(t.track.title).font(Theme.ui(13, .semibold)).foregroundStyle(playing ? Theme.lilac : Theme.text).lineLimit(1)
                Text(t.track.artists.joined(separator: ", ")).font(Theme.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(t.quality ?? t.ext.dropFirst().uppercased()).font(Theme.dot(10)).foregroundStyle(t.quality == "FLAC" ? Theme.lilac : Theme.text2)
                .frame(width: 70, alignment: .trailing)
            switch friends.jobs[t.id] {
            case "fetching": Text("Loading…").font(Theme.ui(11.5)).foregroundStyle(Theme.text2).frame(width: 110)
            case "downloading": Text("Downloading…").font(Theme.ui(11.5)).foregroundStyle(Theme.text2).frame(width: 110)
            case "done": Text("In your library").font(Theme.ui(11.5, .semibold)).foregroundStyle(Theme.lilac).frame(width: 110)
            case let e?: Text("Failed").font(Theme.ui(11.5, .semibold)).foregroundStyle(Theme.peach).help(e).frame(width: 110)
            case nil: PillButton(label: "Download", icon: "arrow.down") { Task { await friends.download(t.id, store: store) } }.frame(width: 110)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { friends.play(t.id, in: share) }
    }

    // MARK: share yours

    private var outgoing: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                DotLabel("New key", color: Theme.text)
                if !remote.signedIn {
                    Text("Sign in to your WreckBox account first (Sync to phone → Use from anywhere).").font(Theme.ui(12.5)).foregroundStyle(Theme.peach)
                } else if remote.url == nil {
                    Text("Friends reach this Mac through \"Use from anywhere\" — turn it on (Sync to phone) and keep WreckBox open while they listen.")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.peach)
                }
                HStack(spacing: 10) {
                    Picker("Share", selection: $sharePlaylist) {
                        Text("Whole library").tag("")
                        ForEach(store.library?.playlists.map(\.name) ?? [], id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 280)
                    TextField("Who it's for (e.g. Sam)", text: $shareLabel).textFieldStyle(.roundedBorder).frame(width: 200)
                    Picker("Expires", selection: $shareDays) {
                        Text("Never").tag(0); Text("7 days").tag(7); Text("30 days").tag(30)
                    }
                    .frame(width: 150)
                    PillButton(label: mine.busy ? "Making…" : "Make key", icon: "key", style: .smart) {
                        Task { await mine.make(playlist: sharePlaylist.isEmpty ? nil : sharePlaylist, label: shareLabel, days: shareDays) }
                    }
                    .disabled(mine.busy || !remote.signedIn)
                }
                if let m = mine.made {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Send your friend the key or the link — it's shown only now.").font(Theme.ui(12.5)).foregroundStyle(Theme.text2)
                        copyRow(m.key, mono: true)
                        copyRow(m.link, mono: false)
                        Text("They can stream and download what you shared, nothing else — they can't change, delete or request anything. Revoke it below any time.")
                            .font(Theme.ui(12)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12).background(RoundedRectangle(cornerRadius: 14).fill(Theme.glassFill))
                }
                if let m = mine.message { Text(m).font(Theme.ui(12.5)).foregroundStyle(Theme.peach) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18).smartGlass(Theme.Radius.tile)

            Scroller {
                LazyVStack(spacing: 2) {
                    if mine.shares.isEmpty {
                        EmptyState(icon: "key", text: "Keys you make show here, with when they were last used.").frame(height: 200)
                    }
                    ForEach(mine.shares) { s in ownRow(s) }
                }
                .padding(6)
            }
            .glass(Theme.Radius.card)
        }
    }

    private func copyRow(_ text: String, mono: Bool) -> some View {
        HStack {
            Text(text).font(mono ? Theme.dot(15) : Theme.ui(12.5)).foregroundStyle(mono ? Theme.peach : Theme.text).textSelection(.enabled).lineLimit(1)
            Spacer()
            PillButton(label: "Copy", icon: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    private func ownRow(_ s: OwnShare) -> some View {
        HStack(spacing: 12) {
            Image(systemName: s.kind == "playlist" ? "music.note.list" : "music.note.house").foregroundStyle(s.revoked ? Theme.text3 : Theme.lilac).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.kind == "playlist" ? (s.playlist ?? "Playlist") : "Whole library").font(Theme.ui(13, .semibold)).lineLimit(1)
                Text([s.label.isEmpty ? nil : "for \(s.label)", "made " + Self.day(s.created),
                      s.lastUsed.map { "last used " + Self.day($0) } ?? "not used yet"].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer()
            if s.revoked {
                Text("Revoked").font(Theme.ui(11.5, .semibold)).foregroundStyle(Theme.text3).frame(width: 100)
            } else {
                PillButton(label: "Revoke", icon: "xmark") { Task { await mine.revoke(s.id) } }.frame(width: 100)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .opacity(s.revoked ? 0.6 : 1)
    }

    private static func day(_ ms: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}
