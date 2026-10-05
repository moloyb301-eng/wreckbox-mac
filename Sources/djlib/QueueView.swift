import SwiftUI

// Download queue: an ordered list of playlists and genres decides which missing tracks are fetched
// first. The resulting order is written to _soulseek/queue.json, which slsk-sync follows.

struct QueueEntry: Identifiable {
    let row: Row
    let reason: String      // the priority that put the track here, "" for "everything else"
    var id: String { row.id }
}

/// A priority is stored as "playlist:<name>" or "genre:<name>".
struct Priority: Hashable {
    let kind: String
    let name: String
    var key: String { "\(kind):\(name)" }

    init(kind: String, name: String) { self.kind = kind; self.name = name }

    init?(_ key: String) {
        guard let i = key.firstIndex(of: ":") else { return nil }
        kind = String(key[..<i]); name = String(key[key.index(after: i)...])
    }
}

extension LibraryStore {
    var priorities: [Priority] { state.downloadPriority.compactMap(Priority.init) }

    /// Missing tracks in download order: each priority's tracks in turn (playlist order, or newest first
    /// for a genre), then — unless `priorityOnly` — everything else, newest first.
    var downloadQueue: [QueueEntry] {
        guard let lib = library else { return [] }
        let missing = lib.tracks.filter { (state.tracks[$0.id]?.status ?? .missing) == .missing }
        let missingIDs = Set(missing.map(\.id))
        let newestFirst = missing.sorted { ($0.firstAdded ?? "") > ($1.firstAdded ?? "") }
        var seen = Set<String>()
        var out: [QueueEntry] = []
        func add(_ id: String, _ reason: String) {
            guard missingIDs.contains(id), seen.insert(id).inserted, let r = row(id) else { return }
            out.append(QueueEntry(row: r, reason: reason))
        }
        for p in priorities {
            if p.kind == "playlist", let pl = lib.playlists.first(where: { $0.name == p.name }) {
                pl.trackIDs.forEach { add($0, p.name) }
            } else if p.kind == "genre" {
                newestFirst.filter { genre(of: $0.id) == p.name }.forEach { add($0.id, p.name) }
            }
        }
        if !state.priorityOnly { newestFirst.forEach { add($0.id, "") } }
        return out
    }

    func setPriorities(_ items: [Priority]) {
        state.downloadPriority = items.map(\.key)
        log("queue", nil, items.isEmpty ? "priorities cleared" : "priorities: " + items.map(\.name).joined(separator: " → "))
        save()
        writeQueue()
    }

    func setPriorityOnly(_ on: Bool) {
        state.priorityOnly = on
        save()
        writeQueue()
    }

    /// Publishes the order for slsk-sync (read at the start of each pass).
    func writeQueue() {
        guard library != nil else { return }
        let payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "onlyPriority": state.priorityOnly,
            "priorities": state.downloadPriority,
            "ids": downloadQueue.map(\.id),
        ]
        try? FileManager.default.createDirectory(at: AppPaths.slskWorkDir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: AppPaths.slskWorkDir.appendingPathComponent("queue.json"), options: .atomic)
        }
    }
}

struct QueueView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var showAll = false

    var body: some View {
        let queue = store.downloadQueue
        let prios = store.priorities
        let counts = Dictionary(grouping: queue, by: \.reason).mapValues(\.count)
        VStack(alignment: .leading, spacing: 16) {
        PageHeader(eyebrow: "Tools", title: "Download queue",
                   subtitle: "Soulseek downloads missing tracks in this order") { EmptyView() }
        HStack(alignment: .top, spacing: 16) {
            // Left: the priority list (scrolls, so a long list never pushes the page past the window)
            Scroller(indicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    DotLabel("Priority", color: Theme.text)
                    if prios.isEmpty {
                        Text("Add playlists and genres below. Their missing tracks go to the front of the queue, top to bottom.")
                            .font(Theme.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(prios.enumerated()), id: \.element) { i, p in
                        PriorityRow(index: i, priority: p, count: counts[p.name] ?? 0, isFirst: i == 0, isLast: i == prios.count - 1,
                                    move: { move(i, by: $0) }, remove: { store.setPriorities(prios.filter { $0 != p }) })
                    }
                    HStack(spacing: 8) {
                        addMenu("Add playlist", icon: "music.note.list",
                                options: (store.library?.playlists ?? []).map(\.name), kind: "playlist", existing: prios)
                        addMenu("Add genre", icon: "tag", options: store.genreCounts.map(\.0), kind: "genre", existing: prios)
                    }
                    Divider().overlay(Theme.hairline)
                    Toggle(isOn: Binding(get: { !store.state.priorityOnly }, set: { store.setPriorityOnly(!$0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Then everything else").font(Theme.ui(13, .semibold))
                            Text("Off: download only your priorities").font(Theme.ui(11.5)).foregroundStyle(Theme.text3)
                        }
                    }
                    .toggleStyle(.switch).tint(Theme.lilac)
                    if !prios.isEmpty {
                        Button("Clear priorities") { store.setPriorities([]) }.buttonStyle(.plain)
                            .font(Theme.ui(12.5, .semibold)).foregroundStyle(Theme.text3)
                    }
                }
                .padding(18)
                .glass(Theme.Radius.tile)

                SoulseekTile(compact: true)
            }
            }
            .frame(width: 380)

            // Right: the resulting queue
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    DotLabel("Queue · \(queue.count) tracks", color: Theme.text)
                    Spacer()
                    if queue.count > 200 {
                        Chip(label: showAll ? "Show first 200" : "Show all", selected: false) { showAll.toggle() }
                    }
                }
                Scroller {
                    LazyVStack(spacing: 2) {
                        ForEach(Array((showAll ? queue : Array(queue.prefix(200))).enumerated()), id: \.element.id) { i, e in
                            HStack(spacing: 12) {
                                Text("\(i + 1)").font(Theme.dot(12)).foregroundStyle(Theme.text3).frame(width: 36, alignment: .trailing)
                                ArtworkView(row: e.row, size: 34, radius: 6)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.row.title).font(Theme.ui(13, .semibold)).lineLimit(1)
                                    Text(e.row.artist).font(Theme.ui(11.5)).foregroundStyle(Theme.text2).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(e.reason.isEmpty ? "everything else" : e.reason)
                                    .font(Theme.ui(11, .semibold)).lineLimit(1)
                                    .foregroundStyle(e.reason.isEmpty ? Theme.text3 : Theme.text)
                                    .padding(.horizontal, 9).padding(.vertical, 3)
                                    .background(Capsule().fill(e.reason.isEmpty ? Theme.glassFill : Theme.lilac.opacity(0.18)))
                                    .frame(maxWidth: 160, alignment: .trailing)
                                Text(e.row.genre).font(Theme.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1).frame(width: 110, alignment: .leading)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(Rectangle())
                            .onTapGesture { store.focus = e.id }
                        }
                    }
                }
            }
            .padding(16)
            .glass(Theme.Radius.card)
        }
        }
        .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 10)
    }

    private func move(_ i: Int, by d: Int) {
        var p = store.priorities
        let j = i + d
        guard p.indices.contains(j) else { return }
        p.swapAt(i, j)
        store.setPriorities(p)
    }

    private func addMenu(_ label: String, icon: String, options: [String], kind: String, existing: [Priority]) -> some View {
        Menu {
            ForEach(options.filter { o in !existing.contains(Priority(kind: kind, name: o)) }, id: \.self) { o in
                Button(o) { store.setPriorities(existing + [Priority(kind: kind, name: o)]) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(Theme.ui(12.5, .semibold))
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Theme.glassFill).overlay(Capsule().strokeBorder(Theme.hairline)))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

struct PriorityRow: View {
    let index: Int
    let priority: Priority
    let count: Int
    let isFirst: Bool
    let isLast: Bool
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)").font(Theme.dot(16)).foregroundStyle(Theme.smart).frame(width: 22)
            Image(systemName: priority.kind == "playlist" ? "music.note.list" : "tag").font(.system(size: 12)).foregroundStyle(Theme.text3)
            VStack(alignment: .leading, spacing: 1) {
                Text(priority.name).font(Theme.ui(13.5, .semibold)).lineLimit(1)
                Text("\(count) missing · \(priority.kind)").font(Theme.ui(11)).foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 4)
            iconButton("chevron.up", disabled: isFirst) { move(-1) }
            iconButton("chevron.down", disabled: isLast) { move(1) }
            iconButton("xmark", disabled: false, action: remove)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.glassFill))
    }

    private func iconButton(_ icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22)
                .foregroundStyle(disabled ? Theme.text3.opacity(0.4) : Theme.text2)
                .background(Circle().fill(Theme.hover))
        }
        .buttonStyle(.plain).disabled(disabled)
    }
}
