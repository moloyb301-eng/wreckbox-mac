import AppKit
import SwiftUI

// "Find manually" on the YouTube page: the tracks neither Soulseek nor YouTube fill could find, listed on the left;
// on the right a YouTube Music search (songs and videos) or a pasted link, downloaded for the selected track by
// yt-fill (`search-json` / `grab`) in your Premium quality and kept in the format YouTube sends (Opus / AAC).

struct YTResult: Identifiable, Decodable {
    var id: String { videoId }
    let videoId: String
    let title: String
    let type: String          // "song" (official audio) or "video"
    let artists: String
    let album: String?
    let duration: String?
    let thumbnail: String?
    let match: Double?
}

@MainActor
final class YouTubeFinder: ObservableObject {
    @Published var results: [YTResult] = []
    @Published var searching = false
    @Published var message: String?
    /// Track id → "downloading" / "done" / an error, for the list on the left.
    @Published var jobs: [String: String] = [:]

    /// yt-fill logs to stdout too: its answer is the last line.
    private func run(_ args: [String]) async -> Data {
        let all = await runRaw(args)
        let lines = all.split(separator: UInt8(ascii: "\n")).filter { !$0.isEmpty }
        return lines.last.map { Data($0) } ?? Data()
    }

    private func runRaw(_ args: [String]) async -> Data {
        await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = AppPaths.ytFill
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")   // ffmpeg, deno
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return Data() }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return data
        }.value
    }

    func search(_ query: String, track: String?) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        message = nil
        defer { searching = false }
        let data = await run(["search-json", q] + (track.map { ["--track", $0] } ?? []))
        if let r = try? JSONDecoder().decode([YTResult].self, from: data) {
            // Best match first, official audio before videos.
            results = r.sorted { ($0.match ?? 0, $0.type == "song" ? 1 : 0) > ($1.match ?? 0, $1.type == "song" ? 1 : 0) }
            if r.isEmpty { message = "Nothing on YouTube for \"\(q)\"." }
        } else {
            results = []
            message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "Search failed — is the internet up?"
        }
    }

    /// Downloads `link` (a video id or any YouTube / YouTube Music link) as `track`; the inbox import files it.
    func grab(_ link: String, for track: String, store: LibraryStore, checked: Bool = false) async {
        if !checked { guard await DownloadGate.allow() else { return } }
        jobs[track] = "downloading"
        let data = await run(["grab", track, link])
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if j["ok"] as? Bool == true {
            jobs[track] = "done"
            store.refreshYouTube()
            await store.importInbox()
        } else {
            jobs[track] = (j["error"] as? String) ?? "Download failed"
        }
    }
}

struct YouTubeFindView: View {
    @EnvironmentObject var store: LibraryStore
    @StateObject private var finder = YouTubeFinder()
    @State private var selected: String?
    @State private var query = ""
    @State private var link = ""
    @State private var filter = ""

    /// Not on this Mac, and both sources gave up (or never had a go).
    private var missing: [Row] {
        let rows = store.rows(.missing, search: filter)
        let tried = Set(store.soulseek.records.filter { ["not_found", "failed"].contains($0.value.status) }.keys)
        return rows.filter { tried.contains($0.id) } + rows.filter { !tried.contains($0.id) }
    }

    var body: some View {
        let list = missing
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    DotLabel("Not found · \(list.count)", color: Theme.text)
                    Spacer()
                }
                TextField("Filter", text: $filter).textFieldStyle(.plain).font(Theme.ui(13))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.glassFill))
                Scroller {
                    LazyVStack(spacing: 2) {
                        ForEach(list) { r in
                            MissingRow(row: r, selected: selected == r.id, job: finder.jobs[r.id])
                                .onTapGesture { pick(r) }
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: 330)
            .glass(Theme.Radius.card)

            VStack(alignment: .leading, spacing: 12) {
                if let id = selected, let r = store.row(id) {
                    HStack(spacing: 12) {
                        ArtworkView(row: r, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.track.title).font(Theme.ui(16, .semibold)).lineLimit(1)
                            Text(r.track.artists.joined(separator: ", ") + (r.track.durationMs.map { " · " + NowPlayingBar.time(Double($0) / 1000) } ?? ""))
                                .font(Theme.ui(12.5)).foregroundStyle(Theme.text2).lineLimit(1)
                        }
                        Spacer()
                        if let j = finder.jobs[id] { JobBadge(job: j) }
                    }
                    HStack(spacing: 8) {
                        field("Search YouTube Music", text: $query) { Task { await finder.search(query, track: id) } }
                        PillButton(label: finder.searching ? "Searching…" : "Search", icon: "magnifyingglass", style: .smart) {
                            Task { await finder.search(query, track: id) }
                        }
                    }
                    HStack(spacing: 8) {
                        field("…or paste a YouTube / YouTube Music link", text: $link) { grabLink(id) }
                        PillButton(label: "Download link", icon: "arrow.down.circle") { grabLink(id) }
                            .disabled(link.isEmpty || finder.jobs[id] == "downloading")
                    }
                    if let m = finder.message { Text(m).font(Theme.ui(12.5)).foregroundStyle(Theme.peach) }
                    Scroller {
                        LazyVStack(spacing: 2) {
                            ForEach(finder.results) { res in
                                YTResultRow(result: res, busy: finder.jobs[id] == "downloading") {
                                    Task { await finder.grab(res.videoId, for: id, store: store) }
                                }
                            }
                        }
                    }
                } else {
                    EmptyState(icon: "magnifyingglass", text: list.isEmpty ? "Nothing missing — every track has a file." : "Pick a track on the left to look for it on YouTube.")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glass(Theme.Radius.card)
        }
        .onAppear { if selected == nil, let first = list.first { pick(first) } }
    }

    private func pick(_ r: Row) {
        selected = r.id
        query = "\(r.track.artists.first ?? "") \(r.track.title)"
        link = ""
        finder.results = []
        Task { await finder.search(query, track: r.id) }
    }

    private func grabLink(_ id: String) {
        let l = link
        guard !l.isEmpty else { return }
        Task {
            await finder.grab(l, for: id, store: store)
            if finder.jobs[id] == "done" { link = "" }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, onSubmit: @escaping () -> Void) -> some View {
        TextField(placeholder, text: text).textFieldStyle(.plain).font(Theme.ui(13))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.glassFill).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline)))
            .onSubmit(onSubmit)
    }
}

private struct MissingRow: View {
    let row: Row
    let selected: Bool
    let job: String?
    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(row: row, size: 34, radius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.track.title).font(Theme.ui(12.5, .semibold)).lineLimit(1)
                Text(row.track.artists.joined(separator: ", ")).font(Theme.ui(11.5)).foregroundStyle(Theme.text2).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let job { JobBadge(job: job) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(selected ? Theme.lilac.opacity(0.18) : .clear))
        .contentShape(Rectangle())
    }
}

private struct JobBadge: View {
    let job: String
    var body: some View {
        let (label, color): (String, Color) = switch job {
        case "downloading": ("Downloading…", Theme.text2)
        case "done": ("Got it", Theme.lilac)
        default: ("Failed", Theme.peach)
        }
        Text(label).font(Theme.ui(11, .semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(color.opacity(0.6)))
            .help(job == "done" || job == "downloading" ? "" : job)
    }
}

private struct YTResultRow: View {
    let result: YTResult
    let busy: Bool
    let download: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: result.thumbnail.flatMap(URL.init(string:))) { img in img.resizable().aspectRatio(contentMode: .fill) }
                placeholder: { Theme.glassFill }
                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).font(Theme.ui(13, .semibold)).lineLimit(1)
                Text([result.artists, result.album, result.duration].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.text2).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(result.type == "song" ? "Audio" : "Video").font(Theme.ui(10.5, .semibold))
                .foregroundStyle(result.type == "song" ? Theme.lilac : Theme.peach)
                .frame(width: 44)
                .help(result.type == "song" ? "Official audio (best)" : "Music video — may have an intro, outro or edits")
            Text(result.match.map { $0 > 0 ? "\(Int($0 * 100))%" : "—" } ?? "").font(Theme.dot(11)).foregroundStyle(Theme.text3)
                .frame(width: 36, alignment: .trailing)
                .help("How well title, artist and length match the track")
            PillButton(label: "Download", icon: "arrow.down") { download() }.disabled(busy)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }
}
