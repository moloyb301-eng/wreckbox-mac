import SwiftUI

// Search: look for anything on Soulseek (through the running slsk-sync — jobs/ files, see serve_jobs) or YouTube
// Music (yt-fill search-json), and download a result into the library. The new track gets an artist and title
// (prefilled from the result), joins the "Search downloads" playlist and is filed, tagged and analysed like any
// other download. Picking for a track that's already in the library is "Find manually" on the YouTube page.

struct SlskResult: Identifiable, Decodable {
    var id: String { user + path }
    let user: String
    let path: String
    let name: String
    let folder: String
    let size: Int
    let ext: String
    let bitrate: Int?
    let seconds: Int?
    let free: Bool
    let speed: Int
    let queue: Int
    let lossless: Bool
}

@MainActor
final class Searcher: ObservableObject {
    @Published var slsk: [SlskResult] = []
    @Published var yt: [YTResult] = []
    @Published var searching = false
    @Published var message: String?
    @Published var jobs: [String: String] = [:]   // result id → "downloading" / "done" / error
    let youtube = YouTubeFinder()

    static var jobsDir: URL { AppPaths.slskWorkDir.appendingPathComponent("jobs") }

    /// Writes a job for slsk-sync and waits for its answer (it checks every second).
    private func job(_ kind: String, _ body: [String: Any], timeout: Double) async -> [String: Any]? {
        let id = UUID().uuidString
        let dir = Self.jobsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let d = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        try? d.write(to: dir.appendingPathComponent("\(id).\(kind).json"), options: .atomic)
        let result = dir.appendingPathComponent("\(id).result.json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(700))
            if let data = try? Data(contentsOf: result) {
                try? FileManager.default.removeItem(at: result)
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
        }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).\(kind).json"))
        return nil
    }

    func search(_ q: String, soulseek: Bool, store: LibraryStore) async {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        message = nil
        defer { searching = false }
        if soulseek {
            store.startSoulseek()
            guard let r = await job("search", ["query": q], timeout: 45) else {
                message = "Soulseek didn't answer — is the Soulseek sync on (Sources → Soulseek)?"
                return
            }
            let data = (try? JSONSerialization.data(withJSONObject: r["results"] ?? [])) ?? Data()
            slsk = (try? JSONDecoder().decode([SlskResult].self, from: data)) ?? []
            if slsk.isEmpty { message = "Nothing on Soulseek for \"\(q)\"." }
        } else {
            await youtube.search(q, track: nil)
            yt = youtube.results
            message = youtube.message
        }
    }

    func grabSlsk(_ r: SlskResult, artist: String, title: String, store: LibraryStore) async {
        guard await DownloadGate.allow() else { return }
        jobs[r.id] = "downloading"
        let track = store.addRequestedTrack(artist: artist, title: title, via: "search")
        let res = await job("grab", ["track": track, "user": r.user, "path": r.path, "size": r.size, "ext": r.ext, "bitrate": r.bitrate as Any], timeout: 900)
        if res?["ok"] as? Bool == true {
            jobs[r.id] = "done"
            await store.importInbox()
        } else {
            jobs[r.id] = (res?["error"] as? String) ?? "No answer from Soulseek"
        }
    }

    func grabYT(_ r: YTResult, artist: String, title: String, store: LibraryStore) async {
        guard await DownloadGate.allow() else { return }
        jobs[r.id] = "downloading"
        let track = store.addRequestedTrack(artist: artist, title: title, via: "search")
        await youtube.grab(r.videoId, for: track, store: store, checked: true)
        jobs[r.id] = youtube.jobs[track] ?? "Download failed"
    }
}

struct SearchView: View {
    @EnvironmentObject var store: LibraryStore
    @StateObject private var s = Searcher()
    @AppStorage("searchSource") private var source = "soulseek"
    @State private var query = ""
    @State private var confirm: (id: String, artist: String, title: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(eyebrow: "Sources", title: "Search", subtitle: "Find anything on Soulseek or YouTube Music and add it to your library") {
                HStack(spacing: 8) {
                    PillButton(label: "Soulseek", icon: "point.3.connected.trianglepath.dotted", style: source == "soulseek" ? .primary : .glass) { source = "soulseek" }
                    PillButton(label: "YouTube", icon: "play.rectangle", style: source == "youtube" ? .primary : .glass) { source = "youtube" }
                }
            }
            HStack(spacing: 8) {
                TextField(source == "soulseek" ? "Artist – title, album, anything…" : "Search YouTube Music", text: $query)
                    .textFieldStyle(.plain).font(Theme.ui(14))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.glassFill).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline)))
                    .onSubmit { go() }
                PillButton(label: s.searching ? "Searching…" : "Search", icon: "magnifyingglass", style: .smart) { go() }.disabled(s.searching)
            }
            if let m = s.message { Text(m).font(Theme.ui(12.5)).foregroundStyle(Theme.peach) }
            Scroller {
                LazyVStack(spacing: 2) {
                    if (source == "soulseek" ? s.slsk.isEmpty : s.yt.isEmpty) && !s.searching {
                        EmptyState(icon: "magnifyingglass", text: source == "soulseek"
                                   ? "Search Soulseek for any track — lossless files show first. Downloads join your library in \"Search downloads\"."
                                   : "Search YouTube Music — official audio is marked Audio. For a track already in your library, use YouTube → Find manually.")
                            .frame(height: 320)
                    }
                    if source == "soulseek" {
                        ForEach(s.slsk) { r in slskRow(r) }
                    } else {
                        ForEach(s.yt) { r in ytRow(r) }
                    }
                }
                .padding(6)
            }
            .glass(Theme.Radius.card)
        }
        .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 10)
    }

    private func go() { Task { await s.search(query, soulseek: source == "soulseek", store: store) } }

    /// "Artist - Title.ext" (or "01 - Artist - Title") → (artist, title); otherwise the query's words.
    private func guess(_ name: String) -> (String, String) {
        let stem = (name as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
        let parts = stem.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && Int($0) == nil }
        if parts.count >= 2 { return (parts[parts.count - 2], parts[parts.count - 1]) }
        return ("", stem)
    }

    private func slskRow(_ r: SlskResult) -> some View {
        HStack(spacing: 12) {
            Text(r.ext.uppercased()).font(Theme.dot(10)).foregroundStyle(r.lossless ? Theme.lilac : Theme.text2).frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(Theme.ui(13, .semibold)).lineLimit(1)
                Text([r.folder, r.user].filter { !$0.isEmpty }.joined(separator: " · ")).font(Theme.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(r.lossless ? "Lossless" : r.bitrate.map { "\($0) kbps" } ?? "?").font(Theme.ui(11.5, .semibold))
                .foregroundStyle(r.lossless ? Theme.lilac : Theme.text2).frame(width: 70, alignment: .trailing)
            Text(String(format: "%.1f MB", Double(r.size) / 1_048_576)).font(Theme.dot(10)).foregroundStyle(Theme.text3).frame(width: 58, alignment: .trailing)
            Text(r.free ? "free" : "queue \(r.queue)").font(Theme.ui(11)).foregroundStyle(r.free ? Theme.text2 : Theme.peach).frame(width: 64, alignment: .trailing)
            downloadButton(r.id) { let g = guess(r.name); confirm = (r.id, g.0, g.1) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .popover(isPresented: Binding(get: { confirm?.id == r.id }, set: { if !$0 { confirm = nil } })) {
            confirmForm { a, t in Task { await s.grabSlsk(r, artist: a, title: t, store: store) } }
        }
    }

    private func ytRow(_ r: YTResult) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: r.thumbnail.flatMap(URL.init(string:))) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Theme.glassFill }
                .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(Theme.ui(13, .semibold)).lineLimit(1)
                Text([r.artists, r.album, r.duration].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(Theme.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(r.type == "song" ? "Audio" : "Video").font(Theme.ui(11, .semibold)).foregroundStyle(r.type == "song" ? Theme.lilac : Theme.peach).frame(width: 50)
            downloadButton(r.id) { confirm = (r.id, r.artists.components(separatedBy: ", ").first ?? r.artists, r.title) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .popover(isPresented: Binding(get: { confirm?.id == r.id }, set: { if !$0 { confirm = nil } })) {
            confirmForm { a, t in Task { await s.grabYT(r, artist: a, title: t, store: store) } }
        }
    }

    @ViewBuilder private func downloadButton(_ id: String, _ action: @escaping () -> Void) -> some View {
        switch s.jobs[id] {
        case "downloading": Text("Downloading…").font(Theme.ui(11.5)).foregroundStyle(Theme.text2).frame(width: 110)
        case "done": Text("In your library").font(Theme.ui(11.5, .semibold)).foregroundStyle(Theme.lilac).frame(width: 110)
        case let e?: Text("Failed").font(Theme.ui(11.5, .semibold)).foregroundStyle(Theme.peach).help(e).frame(width: 110)
        case nil: PillButton(label: "Download", icon: "arrow.down", action: action).frame(width: 110)
        }
    }

    /// Artist / title for the new track, then download.
    private func confirmForm(_ go: @escaping (String, String) -> Void) -> some View {
        ConfirmTrack(artist: confirm?.artist ?? "", title: confirm?.title ?? "") { a, t in
            confirm = nil
            go(a, t)
        }
    }
}

private struct ConfirmTrack: View {
    @State var artist: String
    @State var title: String
    let done: (String, String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DotLabel("Add to your library as", color: Theme.text)
            TextField("Artist", text: $artist).textFieldStyle(.roundedBorder)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            HStack { Spacer(); PillButton(label: "Download", icon: "arrow.down", style: .smart) { done(artist, title) }.disabled(artist.isEmpty || title.isEmpty) }
        }
        .padding(16).frame(width: 320)
    }
}
