import SwiftUI

// Sync results: what Soulseek found and downloaded, what it couldn't find (and why), and what failed,
// with per-track actions: retry, retry with your own search words, try another source, ignore.

enum ResultTab: String, CaseIterable { case done = "Downloaded", notFound = "Not found", failed = "Failed" }

struct SyncResultsView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var browser: SoundCloudBrowser
    @State private var tab: ResultTab = .notFound
    @State private var search = ""
    @State private var customFor: Row?

    var body: some View {
        let s = store.soulseek
        let items = entries(for: tab)
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(eyebrow: "Tools", title: "Sync results",
                       subtitle: "\(s.done) downloaded · \(s.notFound) not found · \(s.failed) failed") {
                HStack(spacing: 8) {
                    if tab != .done && !items.isEmpty {
                        PillButton(label: "Retry all \(items.count)", icon: "arrow.clockwise", style: .smart) {
                            DownloadGate.then { store.retrySync(items.map(\.row.id)) }
                        }
                    }
                    if s.configured && !s.running {
                        PillButton(label: "Start sync", icon: "play.fill") { DownloadGate.then { store.startSoulseek() } }
                    }
                }
            }
            HStack(spacing: 8) {
                ForEach(ResultTab.allCases, id: \.self) { t in
                    Chip(label: t.rawValue, count: count(t, s), selected: tab == t) { tab = t }
                }
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
                    TextField("Filter", text: $search).textFieldStyle(.plain).font(Theme.ui(13))
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .frame(maxWidth: 220)
                .background(Capsule().fill(Theme.glassFill).overlay(Capsule().strokeBorder(Theme.hairline)))
            }
            if !s.running && items.contains(where: { pendingRetry($0.row.id, $0.record, s) != nil }) {
                Text("Retries run when Soulseek sync is running.").font(Theme.ui(12)).foregroundStyle(Theme.peach)
            }
            Scroller {
                LazyVStack(spacing: 2) {
                    if items.isEmpty {
                        Text(emptyText).font(Theme.ui(13)).foregroundStyle(Theme.text3).padding(30)
                    }
                    ForEach(items, id: \.row.id) { e in
                        ResultRow(row: e.row, record: e.record, pending: pendingRetry(e.row.id, e.record, s),
                                  customSearch: { customFor = e.row })
                    }
                }
                .padding(6)
            }
            .glass(Theme.Radius.card)
        }
        .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 10)
        .sheet(item: Binding(get: { customFor.map(IdentifiedRow.init) }, set: { customFor = $0?.row })) { r in
            CustomSearchSheet(row: r.row) { q in DownloadGate.then { store.retrySync([r.row.id], query: q) }; customFor = nil } cancel: { customFor = nil }
        }
    }

    /// A retry request the sync hasn't acted on yet (requested after the last attempt).
    private func pendingRetry(_ id: String, _ rec: SyncRecord, _ s: SoulseekStatus) -> [String: String]? {
        guard let o = s.overrides[id], (o["retryAt"] ?? "") > rec.lastTry else { return nil }
        return o
    }

    private var emptyText: String {
        switch tab {
        case .done: return "Nothing downloaded from Soulseek yet."
        case .notFound: return "Every searched track was found."
        case .failed: return "No failed downloads."
        }
    }

    private func count(_ t: ResultTab, _ s: SoulseekStatus) -> Int {
        switch t { case .done: return s.done; case .notFound: return s.notFound; case .failed: return s.failed }
    }

    private func entries(for t: ResultTab) -> [(row: Row, record: SyncRecord)] {
        let status = t == .done ? "done" : t == .notFound ? "not_found" : "failed"
        let q = normalized(search)
        return store.soulseek.records
            .filter { $0.value.status == status }
            .compactMap { id, rec in store.row(id).map { (row: $0, record: rec) } }
            .filter { t == .done || $0.row.status == .missing }     // hide ones you've since got or ignored
            .filter { q.isEmpty || normalized("\($0.row.artist) \($0.row.title)").contains(q) }
            .sorted { $0.record.lastTry > $1.record.lastTry }
    }
}

private struct IdentifiedRow: Identifiable {
    let row: Row
    var id: String { row.id }
}

struct ResultRow: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var browser: SoundCloudBrowser
    let row: Row
    let record: SyncRecord
    let pending: [String: String]?
    let customSearch: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(row: row, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(Theme.ui(13.5, .semibold)).lineLimit(1)
                Text(row.artist).font(Theme.ui(12)).foregroundStyle(Theme.text2).lineLimit(1)
                Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let p = pending {
                Text(p["query"].map { "Retry queued · “\($0)”" } ?? "Retry queued")
                    .font(Theme.ui(11, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.smart.opacity(0.3)))
            }
            if record.status == "done" {
                if let f = record.format { formatBadge(f) }
                StatusDot(status: row.status)
                    .help(row.status == .downloaded ? "In your crate" : "Waiting in _inbox (not matched to this track yet)")
            } else {
                actions
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.focus = row.id }
    }

    private var detail: String {
        let when = record.date.map { $0.formatted(.relative(presentation: .named)) } ?? ""
        switch record.status {
        case "done":
            let user = record.source?.split(separator: ":").first.map(String.init) ?? "?"
            let size = record.sizeBytes.map { String(format: "%.1f MB", Double($0) / 1_048_576) } ?? ""
            return ["from \(user)", size, when].filter { !$0.isEmpty }.joined(separator: " · ")
        default:
            let q = record.queries.last.map { "searched “\($0)”" } ?? ""
            let tries = record.attempts == 1 ? "1 try" : "\(record.attempts) tries"
            return [record.reason ?? "", q, tries, when].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    private func formatBadge(_ f: String) -> some View {
        let lossless = ["flac", "wav", "aiff", "aif", "alac"].contains(f)
        let label = f.uppercased() + (lossless ? "" : record.bitrate.map { " \(min($0, 320))" } ?? "")
        return Text(label).font(Theme.dot(11)).foregroundStyle(lossless ? Theme.lilac : Theme.text2)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill((lossless ? Theme.lilac : Color.white).opacity(0.12)))
    }

    private var actions: some View {
        HStack(spacing: 6) {
            RoundButton(icon: "arrow.clockwise", help: "Retry on the next pass") { DownloadGate.then { store.retrySync([row.id]) } }
            RoundButton(icon: "text.magnifyingglass", help: "Retry with your own search words", action: customSearch)
            RoundButton(icon: "play.rectangle", help: "Get it from YouTube Music now (official audio)") { DownloadGate.then { store.requestYouTube([row.id]) } }
            Menu {
                Section("Try another source") {
                    Button("SoundCloud") { findOnSoundCloud(store: store, browser: browser, id: row.id) }
                }
                Divider()
                Button("Mark as downloaded") { store.setStatus([row.id], .downloaded) }
                Button("Ignore this track") { store.setStatus([row.id], .ignored) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.glassFill).overlay(Circle().strokeBorder(Theme.hairline)))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }
}

struct CustomSearchSheet: View {
    let row: Row
    let submit: (String) -> Void
    let cancel: () -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DotLabel("Custom search", color: Theme.text)
            Text("\(row.artist) – \(row.title)").font(Theme.ui(16, .semibold))
            Text("Type the words a file name would contain — e.g. drop the featured artists, add “extended mix”, or use the original spelling. Quality rules (lossless first, no low bitrates) still apply.")
                .font(Theme.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            TextField("artist title", text: $query)
                .textFieldStyle(.plain).font(Theme.ui(14))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(Theme.glassFill).overlay(Capsule().strokeBorder(Theme.hairline)))
                .onSubmit { if !query.trimmingCharacters(in: .whitespaces).isEmpty { submit(query) } }
            HStack {
                Spacer()
                PillButton(label: "Cancel", action: cancel)
                PillButton(label: "Search on next pass", icon: "magnifyingglass", style: .primary) { submit(query) }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Theme.bgRaised)
        .onAppear { query = "\(row.track.artists.first ?? "") \(Matcher.cleanTitle(row.title))" }
    }
}
