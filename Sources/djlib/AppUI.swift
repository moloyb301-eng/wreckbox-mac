import AppKit
import SwiftUI

/// Closing the window quits the app, so reopening it always starts the current build.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Stop the Soulseek sync this app started, so it never keeps running orphaned after quitting.
    func applicationWillTerminate(_ notification: Notification) {
        // Stop the tunnel so it doesn't outlive the app.
        let tunnel = Process()
        tunnel.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        tunnel.arguments = ["-f", RemoteAccess.binary.path]
        try? tunnel.run()
        LibraryStore.ytProcess?.terminate()
        guard let p = LibraryStore.syncProcess, p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(100_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }
}

struct DJApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore()
    @StateObject private var browser = SoundCloudBrowser()
    @StateObject private var phoneSync = PhoneSyncServer()
    @StateObject private var updater = Updater()
    @StateObject private var remote = RemoteAccess()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        Theme.registerFonts()
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup("WreckBox") {
            ContentView()
                .environmentObject(store)
                .environmentObject(browser)
                .environmentObject(phoneSync)
                .environmentObject(updater)
                .environmentObject(remote)
                .onAppear { browser.store = store; phoneSync.attach(store); store.startInboxWatcher(); store.refreshSoulseek(); updater.start(); remote.server = phoneSync; remote.store = store; remote.resume()
                    PlaylistSync.installAgent()
                    if store.youtubeFillEnabled { DownloadGate.then { store.startYouTubeFill() } }
                    Task {
                        await store.analyseMissing()      // and anything still without BPM / key / energy
                    }
                    if PlaylistSync.due { Task { await store.syncPlaylists() } }   // missed this morning's run
                    // `djlib organise` (or a request left by it) asks the running app to file the crate.
                    let request = libraryRoot.appendingPathComponent("_cache/organise.request")
                    if FileManager.default.fileExists(atPath: request.path) {
                        try? FileManager.default.removeItem(at: request)
                        Task { await store.rebuildGenresAndOrganise() }
                    }
                    Playback.shared.store = store       // player + device hub (Playback.swift)
                    Playback.shared.server = phoneSync
                    if UserDefaults.standard.bool(forKey: "miniOpen") { MiniPlayerWindow.shared.open(store: store) }
                }
                // wreckbox://share?key=WBX-… (a friend's share link): add it on the Friends page.
                .onOpenURL { url in
                    guard url.host == "share", let key = FriendShares.key(from: url.absoluteString) else { return }
                    store.sidebar = .friends
                    Task { try? await FriendShares.shared.add(key) }
                }
                .frame(minWidth: 980, minHeight: 620)
                .preferredColorScheme(.dark)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Setup…") { NotificationCenter.default.post(name: .showSetup, object: nil) }
            }
            CommandMenu("Player") {
                Button("Play / Pause") { Playback.shared.control(.toggle) }
                Button("Next") { Playback.shared.control(.next) }.keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Previous") { Playback.shared.control(.previous) }.keyboardShortcut(.leftArrow, modifiers: [.command])
                Divider()
                Button("Full Screen Player") { Playback.shared.setFullScreen(!Playback.shared.fullScreen) }.keyboardShortcut("f", modifiers: [.command, .control])
                Button("Mini Player") { MiniPlayerWindow.shared.toggle(store: store) }.keyboardShortcut("m", modifiers: [.command, .option])
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}

// MARK: - Window layout: sidebar | main | inspector

struct ContentView: View {
    @EnvironmentObject var store: LibraryStore
    /// First launch of a shipped app, or WreckBox → Setup… (Setup.swift).
    @State private var showSetup = AppPaths.bundled && !Setup.done

    var body: some View {
        let focused = store.focus.flatMap { store.row($0) }
        GeometryReader { g in
        let overlay = g.size.width < 1320
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                Sidebar().frame(width: 252)
                Group {
                    if let err = store.loadError {
                        EmptyState(icon: "exclamationmark.triangle", text: err)
                    } else {
                        switch store.sidebar {
                        case .home, nil: HomeView()
                        case .soundcloud: SoundCloudView()
                        case .soulseek: SoulseekView()
                        case .youtube: YouTubeView()
                        case .search: SearchView()
                        case .friends: FriendsView()
                        case .queue: QueueView()
                        case .results: SyncResultsView()
                        case .phone: PhoneSyncView()
                        case .scan: ScanView()
                        case .log: LogView()
                        case .files: FilesView()
                        default: TrackListView(item: store.sidebar)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) { NowPlayingBar() }
                if let r = focused, showsInspector, !overlay {
                    Inspector(row: r).frame(width: 340).transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            if let r = focused, showsInspector, overlay {
                Inspector(row: r, floating: true).frame(width: 340)
                    .shadow(color: .black.opacity(0.55), radius: 30, x: -10)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: g.size.width, height: g.size.height)
        .background(AmbientBackground(row: focused))
        .overlay(alignment: .bottomLeading) { UpdateBanner().padding(.leading, 252) }
        .overlay { FullPlayerOverlay() }
        .sheet(isPresented: $showSetup) { SetupView().environmentObject(store) }
        .onReceive(NotificationCenter.default.publisher(for: .showSetup)) { _ in showSetup = true }
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: store.focus)
        }
        .foregroundStyle(Theme.text)
        .font(Theme.ui(13))
    }

    private var showsInspector: Bool {
        switch store.sidebar {
        case .soundcloud, .soulseek, .log, .phone, .scan: return false
        default: return true
        }
    }
}

/// The full-screen player over the whole window while it's on.
struct FullPlayerOverlay: View {
    @ObservedObject var playback = Playback.shared
    var body: some View {
        if playback.fullScreen { FullPlayerView().transition(.opacity) }
    }
}

struct EmptyState: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(Theme.text3)
            Text(text).font(Theme.ui(14)).foregroundStyle(Theme.text2).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Page title + subtitle with actions on the right.
struct PageHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    var subtitle: String = ""
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                DotLabel(eyebrow)
                Text(title).font(Theme.ui(34, .medium)).tracking(-0.4).lineLimit(1)
                if !subtitle.isEmpty { Text(subtitle).font(Theme.ui(13)).foregroundStyle(Theme.text2) }
            }
            Spacer(minLength: 16)
            trailing
        }
    }
}

/// Rescan / reload actions plus the busy indicator, shared by list pages.
struct LibraryActions: View {
    @EnvironmentObject var store: LibraryStore
    @State private var addPlaylist = false
    var body: some View {
        HStack(spacing: 8) {
            if let b = store.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(b).font(Theme.ui(12)).foregroundStyle(Theme.text2).lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(Theme.glassFill))
            }
            PillButton(label: "Add playlist", icon: "plus") { addPlaylist = true }
                .help("Add a playlist from a Spotify / YouTube / YouTube Music link, or import your YouTube Music")
                .sheet(isPresented: $addPlaylist) { AddPlaylistSheet().environmentObject(store) }
            PillButton(label: "Sync playlists", icon: "arrow.triangle.2.circlepath") { Task { await store.syncPlaylists() } }
                .disabled(store.busy != nil)
                .help("Bring in tracks you added to your Spotify playlists (also runs every morning at 7:00)")
            PillButton(label: "Genres & folders", icon: "folder") { Task { await store.rebuildGenresAndOrganise() } }
                .disabled(store.busy != nil)
                .help("Work out genres (Deezer, Last.fm, your playlists), file every track into Tracks/<genre>/ and write genre + \"Energy 1–10\" into the files")
            PillButton(label: "Rescan & analyse", icon: "waveform.badge.magnifyingglass") { Task { await store.rescan() } }
                .disabled(store.busy != nil)
                .help("Read your music folders, relink moved files and analyse BPM / key / energy with Essentia")
            RoundButton(icon: "arrow.clockwise", help: "Reload library.json") { store.reload() }
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var store: LibraryStore
    @State private var showGenres = false
    @State private var addPlaylist = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                WreckBoxIcon(size: 40).frame(width: 34, height: 34)   // same artwork as the app icon
                Text("WRECKBOX").font(Theme.dot(17)).tracking(2)
            }
            .padding(.horizontal, 18).padding(.top, 40).padding(.bottom, 18)
            SyncBox().padding(.horizontal, 8).padding(.bottom, 10)

            Scroller(indicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    SideItem(item: .home, title: "Home", icon: "square.grid.2x2")
                    section("Library")
                    SideItem(item: .all, title: "All tracks", icon: "music.note.list", count: store.library?.tracks.count)
                    SideItem(item: .downloaded, title: "In my crate", icon: "checkmark.circle", count: store.count(.downloaded))
                    SideItem(item: .missing, title: "Missing", icon: "circle.dashed", count: store.count(.missing))
                    SideItem(item: .ignored, title: "Ignored", icon: "nosign", count: store.count(.ignored))
                    SideItem(item: .files, title: "Files on this Mac", icon: "internaldrive", count: store.analysis.count)

                    // "+" right-aligned with the count column (SideItem's 10 pt inner padding)
                    HStack(spacing: 0) {
                        DotLabel("Playlists")
                        Spacer()
                        Button { addPlaylist = true } label: {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
                                .frame(width: 18, height: 18).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("Add a playlist from a Spotify / YouTube link, or import your YouTube Music")
                    }
                    .padding(.leading, 12).padding(.trailing, 10).padding(.top, 18).padding(.bottom, 6)
                    .sheet(isPresented: $addPlaylist) { AddPlaylistSheet().environmentObject(store) }
                    ForEach(store.library?.playlists ?? [], id: \.name) { p in
                        SideItem(item: .playlist(p.name), title: p.name, icon: p.collaborative ? "person.2" : "music.note",
                                 count: p.trackIDs.count,
                                 progress: p.trackIDs.isEmpty ? nil : Double(store.downloadedCount(p)) / Double(p.trackIDs.count))
                    }

                    Button { withAnimation(.easeInOut(duration: 0.2)) { showGenres.toggle() } } label: {
                        HStack {
                            DotLabel("Genres")
                            Image(systemName: showGenres ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text3)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 6)
                    if showGenres {
                        ForEach(store.genreCounts, id: \.0) { g, n in
                            SideItem(item: .genre(g), title: g, icon: "tag", count: n)
                        }
                    }

                    section("Sources")
                    SideItem(item: .soulseek, title: "Soulseek", icon: "arrow.down.to.line", count: store.soulseek.done, live: store.soulseek.running)
                    SideItem(item: .youtube, title: "YouTube", icon: "play.rectangle", count: store.youtube.done, live: store.youtube.running)
                    SideItem(item: .search, title: "Search", icon: "magnifyingglass")
                    SideItem(item: .friends, title: "Friends", icon: "person.2")
                    SideItem(item: .soundcloud, title: "SoundCloud", icon: "cloud")

                    section("Tools")
                    SideItem(item: .queue, title: "Download queue", icon: "list.number", count: store.priorities.isEmpty ? nil : store.priorities.count)
                    SideItem(item: .phone, title: "Sync to phone", icon: "iphone.radiowaves.left.and.right")
                    SideItem(item: .scan, title: "Scan & identify", icon: "waveform.badge.magnifyingglass")
                    SideItem(item: .results, title: "Sync results", icon: "checklist",
                             count: store.soulseek.notFound + store.soulseek.failed == 0 ? nil : store.soulseek.notFound + store.soulseek.failed)
                    SideItem(item: .log, title: "Activity", icon: "clock.arrow.circlepath")
                }
                .padding(.horizontal, 8).padding(.bottom, 16)
            }
        }
        .glass(Theme.Radius.card)
        .padding(.leading, 10).padding(.vertical, 10)
    }

    private func section(_ s: String) -> some View {
        DotLabel(s).padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 6)
    }
}

struct SideItem: View {
    @EnvironmentObject var store: LibraryStore
    let item: SidebarItem
    let title: String
    let icon: String
    var count: Int?
    var progress: Double?
    var live = false
    @State private var hovering = false

    /// Fixed columns, so every row's icon, progress and count line up exactly:
    /// [icon 18] 10 [title …] [indicator 12] 8 [count 40, right-aligned]
    static let iconWidth: CGFloat = 18, indicatorWidth: CGFloat = 12, countWidth: CGFloat = 40

    var body: some View {
        let selected = store.sidebar == item
        Button { store.sidebar = item } label: {
            HStack(spacing: 0) {
                // Every symbol scaled into the same 15×14 box, so wide ones (person.2) don't stick out.
                Image(systemName: icon).resizable().scaledToFit().fontWeight(.medium)
                    .frame(width: 15, height: 14)
                    .frame(width: Self.iconWidth, alignment: .center)
                    .foregroundStyle(selected ? Theme.text : Theme.text3)
                Text(title).font(Theme.ui(13.5, selected ? .semibold : .medium)).lineLimit(1)
                    .foregroundStyle(selected ? Theme.text : Theme.text2)
                    .padding(.leading, 10)
                Spacer(minLength: 6)
                Group {
                    if live {
                        Circle().fill(Theme.smart).frame(width: 6, height: 6)
                    } else if let progress {
                        DotGrid(progress: progress)
                    }
                }
                .frame(width: Self.indicatorWidth, height: Self.indicatorWidth, alignment: .center)
                Text(count.map { $0.formatted() } ?? "")
                    .font(Theme.dot(11)).monospacedDigit().foregroundStyle(Theme.text3).lineLimit(1)
                    .frame(width: Self.countWidth, alignment: .trailing)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.10) : hovering ? Theme.hover : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Download progress as a 3×3 grid of dots: one more turns white for every 10 % of the tracks in your crate
/// (all nine at 90 % and up). Dots fill row by row from the top left.
struct DotGrid: View {
    var progress: Double
    var dot: CGFloat = 3
    var gap: CGFloat = 1.5

    var body: some View {
        let lit = min(9, max(0, Int((progress * 10).rounded(.down))))
        VStack(spacing: gap) {
            ForEach(0..<3, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { c in
                        Circle()
                            .fill(r * 3 + c < lit ? Color.white.opacity(0.95) : Color.white.opacity(0.18))
                            .frame(width: dot, height: dot)
                    }
                }
            }
        }
        .frame(width: dot * 3 + gap * 2, height: dot * 3 + gap * 2)
        .help("\(Int((progress * 100).rounded())) % in your crate")
    }
}

// MARK: - Track list

enum SortKey: String { case none, title, artist, bpm, key, energy, genre, time, quality, status, added }

struct TrackListView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var browser: SoundCloudBrowser
    let item: SidebarItem?
    @State private var search = ""
    @State private var filter = MixFilter()
    @State private var sort: SortKey = .none
    @State private var ascending = true
    @State private var selection = Set<String>()
    @State private var anchor: String?

    var body: some View {
        let rows = sorted(store.rows(item, search: search).filter { filter.allows(bpm: $0.bestBPM, camelot: $0.file?.camelot) })
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(eyebrow: eyebrow, title: title,
                       subtitle: "\(rows.count) tracks · \(rows.filter { $0.status == .downloaded }.count) in your crate") {
                HStack(spacing: 8) {
                    if item == .downloaded, Tagger.available {
                        PillButton(label: "Write tags to files", icon: "tag", style: .smart) { Task { await store.writeTags() } }
                            .disabled(store.busy != nil)
                            .help("Write title, artists, album, year, genre, BPM, key, ISRC and cover art into every file in your crate, so Rekordbox shows the same data. In Rekordbox, select the tracks → right-click → Reload Tag.")
                    }
                    if case .playlist(let name) = item, let pl = store.library?.playlists.first(where: { $0.name == name }) {
                        PillButton(label: "Play", icon: "play.fill", style: .primary) {
                            if let first = pl.trackIDs.first(where: { store.state.tracks[$0]?.status == .downloaded }) { Playback.shared.play(first, list: pl.trackIDs) }
                        }
                        PillButton(label: "Shuffle", icon: "shuffle") { Playback.shared.playShuffled(pl.trackIDs) }
                    }
                    if let p = priority {
                        let rank = store.priorities.firstIndex(of: p)
                        PillButton(label: rank == 0 ? "First in queue" : rank != nil ? "#\(rank! + 1) in queue · move to top" : "Download first",
                                   icon: "list.number", style: .smart) {
                            store.setPriorities([p] + store.priorities.filter { $0 != p })
                        }
                        .disabled(rank == 0)
                        .help("Put this \(p.kind)'s missing tracks at the front of the Soulseek download queue")
                    }
                    LibraryActions()
                }
            }
            FilterRow(search: $search, filter: $filter)
            GeometryReader { g in
            VStack(spacing: 0) {
                ColumnHeader(sort: $sort, ascending: $ascending)
                Divider().overlay(Theme.hairline)
                if rows.isEmpty {
                    EmptyState(icon: "music.note.list", text: search.isEmpty && !filter.isActive ? "Nothing here yet." : "No tracks match.")
                } else {
                    Scroller {
                        LazyVStack(spacing: 2) {
                            ForEach(rows) { r in
                                TrackRowView(row: r, selected: selection.contains(r.id), focused: store.focus == r.id)
                                    .onTapGesture { tap(r, in: rows) }
                                    .contextMenu { TrackMenu(ids: selection.contains(r.id) ? selection : [r.id], filter: $filter) }
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .environment(\.columnFit, ColumnFit(width: g.size.width))
            }
            .glass(Theme.Radius.card)
        }
        .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 10)
        .onChange(of: item) { _ in selection = []; anchor = nil }
    }

    private func tap(_ r: Row, in rows: [Row]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(r.id) { selection.remove(r.id) } else { selection.insert(r.id) }
        } else if flags.contains(.shift), let a = anchor, let i = rows.firstIndex(where: { $0.id == a }), let j = rows.firstIndex(where: { $0.id == r.id }) {
            selection = Set(rows[min(i, j)...max(i, j)].map(\.id))
        } else {
            selection = [r.id]
            anchor = r.id
        }
        store.focus = r.id
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { primaryAction(r) }
    }

    /// Double-click: play it (the list is the queue), or find it on SoundCloud if it isn't here yet.
    private func primaryAction(_ r: Row) {
        if r.state?.localPath != nil, r.status == .downloaded {
            let rows = sorted(store.rows(item, search: search).filter { filter.allows(bpm: $0.bestBPM, camelot: $0.file?.camelot) })
            Playback.shared.play(r.id, list: rows.map(\.id))
        } else {
            findOnSoundCloud(store: store, browser: browser, id: r.id)
        }
    }

    private func sorted(_ rows: [Row]) -> [Row] {
        func by<T: Comparable>(_ k: (Row) -> T) -> [Row] { rows.sorted { ascending ? k($0) < k($1) : k($0) > k($1) } }
        switch sort {
        case .none: return rows
        case .title: return by { $0.title.lowercased() }
        case .artist: return by { $0.artist.lowercased() }
        case .bpm: return by(\.bpmValue)
        case .key: return by(\.camelotSort)
        case .energy: return by(\.energyValue)
        case .genre: return by { $0.genre }
        case .time: return by { $0.track.durationMs ?? 0 }
        // Lossless first, then by bit rate; tracks without a file last.
        case .quality: return by { r -> Int in
            guard let q = r.state?.localPath.flatMap({ store.quality[$0] }) else { return ascending ? Int.max : -1 }
            return q.lossless && !q.fromYouTube ? -2000 : -(q.kbps ?? 0)
        }
        case .status: return by { $0.status.rawValue }
        case .added: return by(\.addedValue)
        }
    }

    private var priority: Priority? {
        switch item {
        case .playlist(let n): return Priority(kind: "playlist", name: n)
        case .genre(let g): return Priority(kind: "genre", name: g)
        default: return nil
        }
    }

    private var eyebrow: String {
        switch item {
        case .playlist: return "Playlist"
        case .genre: return "Genre"
        default: return "Library"
        }
    }

    private var title: String {
        switch item {
        case .playlist(let n): return n
        case .missing: return "Missing"
        case .downloaded: return "In my crate"
        case .ignored: return "Ignored"
        case .genre(let g): return g
        default: return "All tracks"
        }
    }
}

@MainActor
func findOnSoundCloud(store: LibraryStore, browser: SoundCloudBrowser, id: String) {
    guard let t = store.track(id) else { return }
    store.pendingTrackID = id
    store.sidebar = .soundcloud
    browser.search("\(t.artists.first ?? "") \(t.title)")
}

/// Which optional columns fit, from the list's width.
struct ColumnFit: Equatable {
    var energy = true
    var genre = true
    var quality = true
    init(width: CGFloat = 2000) { genre = width >= 940; energy = width >= 780; quality = width >= 640 }
}

private struct ColumnFitKey: EnvironmentKey { static let defaultValue = ColumnFit() }
extension EnvironmentValues {
    var columnFit: ColumnFit {
        get { self[ColumnFitKey.self] }
        set { self[ColumnFitKey.self] = newValue }
    }
}

/// Column widths shared by the header and rows.
enum Col {
    static let art: CGFloat = 40, bpm: CGFloat = 60, key: CGFloat = 66, energy: CGFloat = 56, genre: CGFloat = 130, quality: CGFloat = 72, time: CGFloat = 46, status: CGFloat = 26
}

struct ColumnHeader: View {
    @Environment(\.columnFit) private var fit
    @Binding var sort: SortKey
    @Binding var ascending: Bool

    var body: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: Col.art, height: 1)
            head("Title", .title).frame(maxWidth: .infinity, alignment: .leading)
            head("BPM", .bpm).frame(width: Col.bpm, alignment: .leading)
            head("Key", .key).frame(width: Col.key, alignment: .leading)
            if fit.energy { head("Energy", .energy).frame(width: Col.energy, alignment: .leading) }
            if fit.genre { head("Genre", .genre).frame(width: Col.genre, alignment: .leading) }
            if fit.quality { head("Quality", .quality).frame(width: Col.quality, alignment: .leading) }
            head("Time", .time).frame(width: Col.time, alignment: .trailing)
            head("", .status).frame(width: Col.status)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private func head(_ label: String, _ key: SortKey) -> some View {
        Button {
            if sort == key { if ascending { ascending = false } else { sort = .none; ascending = true } }
            else { sort = key; ascending = true }
        } label: {
            HStack(spacing: 4) {
                DotLabel(label, color: sort == key ? Theme.text : Theme.text3, size: 10)
                if sort == key { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct TrackRowView: View {
    @Environment(\.columnFit) private var fit
    @EnvironmentObject var store: LibraryStore
    let row: Row
    let selected: Bool
    let focused: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(row: row, size: Col.art)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(Theme.ui(13.5, .semibold)).lineLimit(1)
                Text(row.artist).font(Theme.ui(12)).foregroundStyle(Theme.text2).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            BPMReadout(bpm: row.bestBPM, unsure: row.bpmText.hasSuffix("?")).frame(width: Col.bpm, alignment: .leading)
                .help(row.bpmSource)
            KeyBadge(camelot: row.camelot, unsure: row.keyUnsure).frame(width: Col.key, alignment: .leading).help(row.keyText)
            if fit.energy { EnergyMeter(value: row.energy).frame(width: Col.energy, alignment: .leading) }
            if fit.genre {
                Text(row.genre).font(Theme.ui(12)).foregroundStyle(row.genreUnsure ? Theme.text3 : Theme.text2).lineLimit(1)
                    .frame(width: Col.genre, alignment: .leading).help(row.genreHelp)
            }
            if fit.quality {
                let q = row.state?.localPath.flatMap { store.quality[$0] }
                Text(q?.label ?? (row.status == .downloaded ? "…" : ""))
                    .font(Theme.dot(11.5)).monospacedDigit().foregroundStyle(q?.color ?? Theme.text3).lineLimit(1)
                    .frame(width: Col.quality, alignment: .leading)
                    .help(q?.detail ?? "")
            }
            Text(row.durationText).font(Theme.dot(12)).foregroundStyle(Theme.text3).frame(width: Col.time, alignment: .trailing)
            StatusDot(status: row.status).frame(width: Col.status).help(row.state?.localPath ?? row.statusText)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(selected ? Color.white.opacity(0.10) : hovering ? Theme.hover : .clear)
                .overlay {
                    if focused { RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.smart.opacity(0.7), lineWidth: 1) }
                }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Right-click menu for one or more tracks.
struct TrackMenu: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var browser: SoundCloudBrowser
    let ids: Set<String>
    @Binding var filter: MixFilter

    var body: some View {
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
            DownloadGate.then { Task { await browser.bulkDownload(Array(ids)) } }
        }
        .disabled(browser.bulkRunning)
        if ids.count == 1, let id = ids.first, let r = store.row(id) {
            if !r.camelot.isEmpty {
                Button("Show tracks that mix with \(r.camelot)") { filter.key = r.camelot; filter.compatible = true }
            }
            Divider()
            if r.status == .downloaded, r.state?.localPath != nil {
                Button("Play") { Playback.shared.play(id, list: [id]) }
            }
            Button("Find on SoundCloud") { findOnSoundCloud(store: store, browser: browser, id: id) }
            if let p = r.state?.localPath {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
            }
        }
    }
}

// MARK: - Filters

struct FilterRow: View {
    @Binding var search: String
    @Binding var filter: MixFilter
    var placeholder = "Search artist, title, album"
    static let keys = (1...12).flatMap { ["\($0)A", "\($0)B"] }
    static let presets: [(String, String, String)] = [("< 100", "", "99"), ("100–120", "100", "120"), ("120–130", "120", "130"),
                                                      ("130–145", "130", "145"), ("145+", "145", "")]

    var body: some View {
        // Drop the BPM preset chips when the window is too narrow for them.
        ViewThatFits(in: .horizontal) {
            content(presets: true)
            content(presets: false)
        }
    }

    private func content(presets: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
                TextField(placeholder, text: $search).textFieldStyle(.plain).font(Theme.ui(13))
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text3) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(minWidth: 150, idealWidth: 240, maxWidth: 260)
            .background(Capsule().fill(Theme.glassFill).overlay(Capsule().strokeBorder(Theme.hairline)))

            DotLabel("BPM", size: 10).padding(.leading, 6)
            ForEach(presets ? Self.presets : [], id: \.0) { label, lo, hi in
                Chip(label: label, selected: filter.minBPM == lo && filter.maxBPM == hi) {
                    if filter.minBPM == lo && filter.maxBPM == hi { filter.minBPM = ""; filter.maxBPM = "" }
                    else { filter.minBPM = lo; filter.maxBPM = hi }
                }
            }
            HStack(spacing: 4) {
                TextField("min", text: $filter.minBPM).frame(width: 34)
                Text("–").foregroundStyle(Theme.text3)
                TextField("max", text: $filter.maxBPM).frame(width: 34)
            }
            .textFieldStyle(.plain).font(Theme.dot(12)).multilineTextAlignment(.center)
            .padding(.horizontal, 10).padding(.vertical, 6.5)
            .background(Capsule().fill(Theme.glassFill).overlay(Capsule().strokeBorder(Theme.hairline)))

            Menu {
                Button("Any key") { filter.key = "" }
                Divider()
                ForEach(Self.keys, id: \.self) { k in Button(k) { filter.key = k } }
            } label: {
                HStack(spacing: 6) {
                    if filter.key.isEmpty { Text("Any key").font(Theme.ui(12.5, .semibold)) }
                    else { KeyBadge(camelot: filter.key) }
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 12).padding(.vertical, filter.key.isEmpty ? 6.5 : 3)
                .background(Capsule().fill(Theme.glassFill).overlay(Capsule().strokeBorder(Theme.hairline)))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

            if !filter.key.isEmpty {
                Chip(label: "+ compatible keys", selected: false, smart: filter.compatible) { filter.compatible.toggle() }
                    .help("Include keys one step around the Camelot wheel and the relative major/minor")
            }
            Spacer(minLength: 0)
            if filter.isActive {
                Button("Clear") { filter = MixFilter() }.buttonStyle(.plain).font(Theme.ui(12.5, .semibold)).foregroundStyle(Theme.text2)
            }
        }
    }
}

// MARK: - Inspector

struct Inspector: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var browser: SoundCloudBrowser
    let row: Row
    /// Floating over the list (narrow windows): needs a solid backing so the list doesn't show through.
    var floating = false

    var body: some View {
        Scroller(indicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    DotLabel(row.status == .downloaded ? "In your crate" : row.status == .ignored ? "Ignored" : "Missing")
                    Spacer()
                    RoundButton(icon: "xmark", help: "Close") { store.focus = nil }
                }
                ArtworkView(row: row, size: 300, radius: 20)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title).font(Theme.ui(22, .semibold)).lineLimit(3)
                    Text(row.artist).font(Theme.ui(15)).foregroundStyle(Theme.text2)
                    Text([row.track.album, row.track.year].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.ui(12)).foregroundStyle(Theme.text3).lineLimit(2)
                }

                HStack(spacing: 8) {
                    readout("BPM") {
                        BPMReadout(bpm: row.bestBPM, unsure: row.bpmText.hasSuffix("?"), size: 28)
                        if let alt = row.file?.bpmAlternate { Text("or \(Int(alt.rounded()))").font(Theme.dot(11)).foregroundStyle(Theme.text3) }
                    }
                    readout("Key") {
                        KeyBadge(camelot: row.camelot, unsure: row.keyUnsure, large: true)
                        Text(row.keyText.isEmpty ? " " : row.keyText).font(Theme.ui(11)).foregroundStyle(Theme.text3)
                    }
                    readout("Energy") {
                        EnergyMeter(value: row.energy, height: 22)
                        Text(row.energy.map { "\(Int($0 * 100))%" } ?? "–").font(Theme.dot(11)).foregroundStyle(Theme.text3)
                    }
                }
                Text(analysisNote).font(Theme.ui(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)

                if !row.genre.isEmpty || !row.track.playlists.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        DotLabel("Genre & playlists")
                        FlowChips(items: ([row.genre].filter { !$0.isEmpty }) + row.track.playlists)
                    }
                }

                MixesWithCard(row: row)

                VStack(alignment: .leading, spacing: 8) {
                    if row.status == .downloaded, let p = row.state?.localPath {
                        HStack(spacing: 8) {
                            PillButton(label: "Show in Finder", icon: "folder", style: .primary) {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                            }
                            PillButton(label: "Open", icon: "play.fill") { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
                        }
                        if Tagger.available {
                            PillButton(label: "Write tags to file", icon: "tag", style: .smart) { Task { await store.writeTags([row.id]) } }
                                .disabled(store.busy != nil)
                                .help("Write this track's title, artists, album, BPM, key, ISRC and cover into the file")
                        }
                        Text(p.replacingOccurrences(of: home.path, with: "~")).font(Theme.ui(11)).foregroundStyle(Theme.text3).lineLimit(3)
                    } else {
                        HStack(spacing: 8) {
                            PillButton(label: "Find on SoundCloud", icon: "cloud", style: .primary) {
                                findOnSoundCloud(store: store, browser: browser, id: row.id)
                            }
                            if row.status == .missing {
                                PillButton(label: "Ignore", icon: "nosign") { store.setStatus([row.id], .ignored) }
                            } else {
                                PillButton(label: "Un-ignore", icon: "arrow.uturn.left") { store.setStatus([row.id], .missing) }
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
        .background {
            if floating { RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.bgRaised.opacity(0.96)) }
        }
        .glass(Theme.Radius.card)
        .padding(.vertical, 10).padding(.trailing, 10)
    }

    private var analysisNote: String {
        guard let f = row.file else {
            if row.status == .downloaded {
                return "File not analysed yet — click Rescan & analyse (it also finds files you've moved)."
            }
            return row.bestBPM == nil ? "Not on this Mac yet — no analysis." : "Not on this Mac yet — BPM \(row.bpmSource)."
        }
        if f.engine == "essentia" {
            var parts = ["Full-track analysis (Essentia)"]
            if let c = f.bpmConfidence { parts.append("tempo confidence \(Int(c * 100))%") }
            if let a = f.keyAgreement { parts.append("key \(a)/3 methods agree") }
            if let l = f.loudnessLUFS { parts.append(String(format: "%.1f LUFS", l)) }
            return parts.joined(separator: " · ")
        }
        return "Built-in analysis — run Rescan & analyse for Essentia results."
    }

    private func readout<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DotLabel(label, size: 10)
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .padding(12)
        .glass(16, shadow: false)
    }
}

/// Small wrapping chips.
struct FlowChips: View {
    let items: [String]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { s in
                Text(s).font(Theme.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Theme.glassFill).overlay(Capsule().strokeBorder(Theme.hairline)))
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += lineH + spacing; lineH = 0 }
            x += sz.width + spacing; lineH = max(lineH, sz.height)
        }
        return CGSize(width: width, height: y + lineH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += lineH + spacing; lineH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing; lineH = max(lineH, sz.height)
        }
    }
}

/// Smart card: tracks you have that mix with the selected one.
struct MixesWithCard: View {
    @EnvironmentObject var store: LibraryStore
    let row: Row

    var body: some View {
        let mixes = store.mixesWith(row)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                DotLabel("Mixes with", color: Theme.text)
                Spacer()
                if !row.camelot.isEmpty { Text("\(Analyzer.compatible(row.camelot).sorted().joined(separator: " "))").font(Theme.dot(10)).foregroundStyle(Theme.text2) }
            }
            if row.camelot.isEmpty || row.bestBPM == nil {
                Text("Needs a key and BPM — available once the track is on this Mac and analysed.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.text2)
            } else if mixes.isEmpty {
                Text("Nothing in your library within ±6% tempo in a compatible key yet.").font(Theme.ui(12)).foregroundStyle(Theme.text2)
            } else {
                ForEach(mixes) { m in
                    Button { store.focus = m.id } label: {
                        HStack(spacing: 10) {
                            ArtworkView(row: m, size: 30, radius: 6)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.title).font(Theme.ui(12.5, .semibold)).lineLimit(1)
                                Text(m.artist).font(Theme.ui(11)).foregroundStyle(Theme.text2).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            BPMReadout(bpm: m.bestBPM, size: 13)
                            KeyBadge(camelot: m.camelot)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .smartGlass(18)
    }
}

// MARK: - Files on this Mac

struct FileRow: Identifiable {
    let a: FileAnalysis
    let inLibrary: String
    var id: String { a.path }
    var name: String { (a.path as NSString).lastPathComponent }
    var folder: String { (a.path as NSString).deletingLastPathComponent.replacingOccurrences(of: home.path, with: "~") }
    var bpmValue: Double { a.bpm ?? -1 }
    var camelot: String { a.camelot ?? "" }
    var camelotSort: Int { camelotOrder(a.camelot) }
    var artist: String { a.artist ?? "" }
    var title: String { a.title ?? "" }
    var durationText: String { a.durationSec.map { String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) } ?? "" }
}

/// Every audio file found in the scan folders, matched to the Spotify library or not.
struct FilesView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var search = ""
    @State private var filter = MixFilter()
    @State private var selected: String?
    @State private var showSamples = false

    var body: some View {
        let q = normalized(search)
        let all = store.analysis.values.map { FileRow(a: $0, inLibrary: $0.libraryTrackID.map { store.describe($0) } ?? "") }
        let samples = all.filter { ($0.a.durationSec ?? 0) < 30 }.count
        let rows = all
            .filter { showSamples || ($0.a.durationSec ?? 0) >= 30 }
            .filter { q.isEmpty || normalized("\($0.artist) \($0.title) \($0.name)").contains(q) }
            .filter { filter.allows(bpm: $0.a.bpm, camelot: $0.a.camelot) }
            .sorted { ($0.a.bpm ?? .infinity) < ($1.a.bpm ?? .infinity) }
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(eyebrow: "Library", title: "Files on this Mac",
                       subtitle: store.analysis.isEmpty ? "Click Rescan & analyse to read your music folders" : "\(rows.count) files · sorted by BPM") {
                LibraryActions()
            }
            HStack(spacing: 8) {
                FilterRow(search: $search, filter: $filter, placeholder: "Search artist, title, file name")
                if samples > 0 { Chip(label: "Clips under 30 s", count: samples, selected: showSamples) { showSamples.toggle() } }
            }
            Scroller {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { r in
                        HStack(spacing: 12) {
                            Image(systemName: r.a.libraryTrackID == nil ? "doc" : "link")
                                .foregroundStyle(r.a.libraryTrackID == nil ? Theme.text3 : Theme.lilac).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title.isEmpty ? r.name : r.artist.isEmpty ? r.title : "\(r.artist) – \(r.title)").font(Theme.ui(13.5, .semibold)).lineLimit(1)
                                Text(r.folder + "/" + r.name).font(Theme.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            BPMReadout(bpm: r.a.bpm, unsure: r.a.bpmAmbiguous).frame(width: Col.bpm, alignment: .leading)
                            KeyBadge(camelot: r.camelot, unsure: r.a.keyUnsure).frame(width: Col.key, alignment: .leading)
                            EnergyMeter(value: r.a.energy).frame(width: Col.energy, alignment: .leading)
                            Text(r.durationText).font(Theme.dot(12)).foregroundStyle(Theme.text3).frame(width: Col.time, alignment: .trailing)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(selected == r.id ? Color.white.opacity(0.10) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selected = r.id
                            if let id = r.a.libraryTrackID { store.focus = id }
                            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { NSWorkspace.shared.open(URL(fileURLWithPath: r.id)) }
                        }
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.id)]) }
                            if !r.camelot.isEmpty { Button("Show files that mix with \(r.camelot)") { filter.key = r.camelot; filter.compatible = true } }
                        }
                    }
                }
                .padding(6)
            }
            .glass(Theme.Radius.card)
        }
        .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 10)
    }
}

// MARK: - Activity log

struct LogView: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(eyebrow: "Tools", title: "Activity", subtitle: "\(store.state.log.count) events") { EmptyView() }
            Scroller {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(store.state.log.reversed()) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(Theme.dot(11)).foregroundStyle(Theme.text3)
                                .frame(width: 150, alignment: .leading)
                            Text(e.event).font(Theme.ui(11.5, .semibold)).foregroundStyle(color(e.event))
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .background(Capsule().fill(color(e.event).opacity(0.14)))
                                .frame(width: 150, alignment: .leading)
                            Text(e.detail).font(Theme.ui(12.5)).foregroundStyle(Theme.text2).lineLimit(2)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                    }
                }
                .padding(6)
            }
            .glass(Theme.Radius.card)
        }
        .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 10)
    }

    private func color(_ event: String) -> Color {
        if event.contains("downloaded") || event == "found" { return Theme.lilac }
        if event.contains("fail") || event.contains("gone") || event.contains("unmatched") { return Theme.peach }
        if event == "soulseek" { return Theme.lightBlue }
        return Theme.text2
    }
}

extension Notification.Name {
    static let showSetup = Notification.Name("WreckBoxShowSetup")
}
