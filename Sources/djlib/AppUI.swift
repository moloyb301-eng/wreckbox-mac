import AppKit
import SwiftUI

struct DJApp: App {
    @StateObject private var store = LibraryStore()
    @StateObject private var browser = SoundCloudBrowser()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup("DJ Library") {
            ContentView()
                .environmentObject(store)
                .environmentObject(browser)
                .onAppear { browser.store = store; store.startInboxWatcher() }
                .frame(minWidth: 1000, minHeight: 620)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        NavigationSplitView {
            List(selection: $store.sidebar) {
                Section("Library") {
                    Label("All tracks", systemImage: "music.note.list").badge(store.library?.tracks.count ?? 0).tag(SidebarItem.all)
                    Label("Downloaded", systemImage: "checkmark.circle").badge(store.count(.downloaded)).tag(SidebarItem.downloaded)
                    Label("Missing", systemImage: "circle.dashed").badge(store.count(.missing)).tag(SidebarItem.missing)
                    Label("Ignored", systemImage: "nosign").badge(store.count(.ignored)).tag(SidebarItem.ignored)
                    Label("Files on this Mac", systemImage: "internaldrive").badge(store.analysis.count).tag(SidebarItem.files)
                }
                Section("Playlists") {
                    ForEach(store.library?.playlists ?? [], id: \.name) { p in
                        Label(p.name, systemImage: p.collaborative ? "person.2" : "list.bullet").badge(p.trackIDs.count).tag(SidebarItem.playlist(p.name))
                    }
                }
                Section("Genres") {
                    ForEach(store.genreCounts, id: \.0) { g, n in
                        Label(g, systemImage: "tag").badge(n).tag(SidebarItem.genre(g))
                    }
                }
                Section("Tools") {
                    Label("SoundCloud", systemImage: "cloud").tag(SidebarItem.soundcloud)
                    Label("Activity log", systemImage: "clock.arrow.circlepath").tag(SidebarItem.log)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let err = store.loadError {
                ContentUnavailable(text: err)
            } else {
                switch store.sidebar {
                case .soundcloud: SoundCloudView()
                case .log: LogView()
                case .files: FilesTable()
                default: TrackTable(item: store.sidebar)
                }
            }
        }
        .toolbar {
            if let b = store.busy { ProgressView().controlSize(.small); Text(b).foregroundStyle(.secondary) }
            Button { Task { await store.rescan() } } label: { Label("Rescan folders", systemImage: "arrow.triangle.2.circlepath") }
                .disabled(store.busy != nil)
                .help("Read tags in your music folders and mark matching tracks as downloaded")
            Button { store.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                .help("Reload library.json and the BPM cache")
        }
    }
}

struct ContentUnavailable: View {
    let text: String
    var body: some View { Text(text).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity) }
}

struct TrackTable: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var browser: SoundCloudBrowser
    let item: SidebarItem?
    @State private var search = ""
    @State private var selection = Set<String>()
    @State private var sortOrder: [KeyPathComparator<Row>] = []
    @State private var filter = MixFilter()

    var body: some View {
        let rows = store.rows(item, search: search).filter { filter.allows(bpm: $0.bestBPM, camelot: $0.file?.camelot) }.sorted(using: sortOrder)
        VStack(spacing: 0) {
        FilterBar(filter: $filter)
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("", value: \.statusText) { r in
                Image(systemName: r.status == .downloaded ? "checkmark.circle.fill" : r.status == .ignored ? "nosign" : "circle.dashed")
                    .foregroundStyle(r.status == .downloaded ? .green : .secondary)
                    .help(r.state?.localPath ?? r.statusText)
            }
            .width(24)
            TableColumn("BPM", value: \.bpmValue) { r in
                Text(r.bpmText).monospacedDigit().foregroundStyle(r.file?.bpm != nil ? .primary : .secondary).help(r.bpmSource)
            }.width(48)
            TableColumn("Key", value: \.camelotSort) { r in Text(r.camelot).help(r.keyText) }.width(40)
            TableColumn("Artist", value: \.artist)
            TableColumn("Title", value: \.title)
            TableColumn("Genre", value: \.genre) { r in
                Text(r.genre + (r.genreUnsure && !r.genre.isEmpty ? " ?" : "")).foregroundStyle(r.genreUnsure ? .secondary : .primary).help(r.genreHelp)
            }
            TableColumn("Time", value: \.durationText).width(48)
            TableColumn("Playlists", value: \.playlistsText)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Mark as downloaded") { store.setStatus(ids, .downloaded) }
            Button("Mark as missing") { store.setStatus(ids, .missing) }
            Button("Ignore") { store.setStatus(ids, .ignored) }
            Menu("Set genre") {
                ForEach(GenreTool.allGenres, id: \.self) { g in Button(g) { store.setGenre(ids, g) } }
                Divider()
                Button("Use detected genre") { store.setGenre(ids, nil) }
            }
            Button("Bulk download from SoundCloud (\(ids.count))") {
                store.sidebar = .soundcloud
                Task { await browser.bulkDownload(Array(ids)) }
            }
            .disabled(browser.bulkRunning)
            if ids.count == 1, let id = ids.first {
                if let c = store.rows(.all, search: "").first(where: { $0.id == id })?.file?.camelot {
                    Button("Show tracks that mix with \(c)") { filter.key = c; filter.compatible = true }
                }
                Divider()
                Button("Find on SoundCloud") { find(id) }
                if let p = store.state.tracks[id]?.localPath {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, store.state.tracks[id]?.status != .downloaded { find(id) }
        }
        }
        .searchable(text: $search, prompt: "Artist, title, album")
        .navigationTitle(title)
        .navigationSubtitle("\(rows.count) tracks · \(rows.filter { $0.status == .downloaded }.count) downloaded")
    }

    private var title: String {
        switch item {
        case .playlist(let n): return n
        case .missing: return "Missing"
        case .downloaded: return "Downloaded"
        case .ignored: return "Ignored"
        case .genre(let g): return g
        default: return "All tracks"
        }
    }

    private func find(_ id: String) {
        guard let t = store.track(id) else { return }
        store.pendingTrackID = id
        store.sidebar = .soundcloud
        browser.search("\(t.artists.first ?? "") \(t.title)")
    }
}

struct LogView: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        Table(store.state.log.reversed()) {
            TableColumn("When") { e in Text(e.date.formatted(date: .abbreviated, time: .shortened)) }.width(150)
            TableColumn("Event", value: \.event).width(140)
            TableColumn("Detail", value: \.detail)
        }
        .navigationTitle("Activity log")
    }
}

struct FilterBar: View {
    @Binding var filter: MixFilter
    static let keys = (1...12).flatMap { ["\($0)A", "\($0)B"] }

    var body: some View {
        HStack(spacing: 8) {
            Text("BPM").foregroundStyle(.secondary)
            TextField("min", text: $filter.minBPM).frame(width: 50)
            Text("–").foregroundStyle(.secondary)
            TextField("max", text: $filter.maxBPM).frame(width: 50)
            Divider().frame(height: 16)
            Picker("Key", selection: $filter.key) {
                Text("Any").tag("")
                ForEach(Self.keys, id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 120)
            Toggle("+ compatible", isOn: $filter.compatible).disabled(filter.key.isEmpty)
                .help("Include keys one step around the Camelot wheel and the relative major/minor")
            Spacer()
            if filter.isActive { Button("Clear") { filter = MixFilter() } }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

struct FileRow: Identifiable {
    let a: FileAnalysis
    let inLibrary: String
    var id: String { a.path }
    var name: String { (a.path as NSString).lastPathComponent }
    var folder: String { (a.path as NSString).deletingLastPathComponent.replacingOccurrences(of: home.path, with: "~") }
    var bpmValue: Double { a.bpm ?? -1 }
    var bpmText: String { a.bpm.map { String(format: "%.0f", $0) + (a.bpmAmbiguous ? "?" : "") } ?? "" }
    var camelot: String { a.camelot ?? "" }
    var camelotSort: Int { camelotOrder(a.camelot) }
    var artist: String { a.artist ?? "" }
    var title: String { a.title ?? "" }
    var durationText: String { a.durationSec.map { String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) } ?? "" }
}

/// Every audio file found in the scan folders, matched to the Spotify library or not.
struct FilesTable: View {
    @EnvironmentObject var store: LibraryStore
    @State private var search = ""
    @State private var filter = MixFilter()
    @State private var selection = Set<String>()
    @State private var sortOrder: [KeyPathComparator<FileRow>] = [KeyPathComparator(\.bpmValue)]

    var body: some View {
        let q = normalized(search)
        let rows = store.analysis.values
            .map { FileRow(a: $0, inLibrary: $0.libraryTrackID.map { store.describe($0) } ?? "") }
            .filter { q.isEmpty || normalized("\($0.artist) \($0.title) \($0.name)").contains(q) }
            .filter { filter.allows(bpm: $0.a.bpm, camelot: $0.a.camelot) }
            .sorted(using: sortOrder)
        VStack(spacing: 0) {
            FilterBar(filter: $filter)
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("BPM", value: \.bpmValue) { r in Text(r.bpmText).monospacedDigit() }.width(48)
                TableColumn("Key", value: \.camelotSort) { r in Text(r.camelot).help(r.a.key ?? "") }.width(40)
                TableColumn("Artist", value: \.artist)
                TableColumn("Title", value: \.title)
                TableColumn("File", value: \.name)
                TableColumn("Time", value: \.durationText).width(48)
                TableColumn("Folder", value: \.folder)
                TableColumn("In Spotify library", value: \.inLibrary)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) }) }
                if ids.count == 1, let c = ids.first.flatMap({ store.analysis[$0]?.camelot }) {
                    Button("Show files that mix with \(c)") { filter.key = c; filter.compatible = true }
                }
            } primaryAction: { ids in
                ids.first.map { NSWorkspace.shared.open(URL(fileURLWithPath: $0)) }
            }
        }
        .searchable(text: $search, prompt: "Artist, title, file name")
        .navigationTitle("Files on this Mac")
        .navigationSubtitle(rows.isEmpty && store.analysis.isEmpty ? "Click Rescan folders to analyse your music" : "\(rows.count) files")
    }
}
