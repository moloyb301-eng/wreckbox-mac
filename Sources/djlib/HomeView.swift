import SwiftUI

// Home dashboard: library stats, Soulseek sync, recently added tracks and playlist tiles.

struct HomeView: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        let total = store.library?.tracks.count ?? 0
        let have = store.count(.downloaded)
        let analysed = store.analysis.values.filter { $0.engine == "essentia" }.count
        Scroller(indicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                PageHeader(eyebrow: Date().formatted(.dateTime.weekday(.wide).day().month(.wide)),
                           title: "Your crate",
                           subtitle: "\(total) tracks from \(store.library?.playlists.count ?? 0) playlist\(store.library?.playlists.count == 1 ? "" : "s")") {
                    LibraryActions()
                }

                HStack(spacing: 12) {
                    StatTile(label: "Tracks", value: "\(total)", detail: "across all playlists")
                    StatTile(label: "In crate", value: "\(have)", detail: total > 0 ? "\(Int(Double(have) / Double(total) * 100))% of your library" : nil,
                             progress: total > 0 ? Double(have) / Double(total) : 0)
                    StatTile(label: "Missing", value: "\(store.count(.missing))", detail: "\(store.count(.ignored)) ignored")
                    StatTile(label: "Analysed", value: "\(analysed)", detail: "BPM · key · energy (Essentia)")
                }
                .fixedSize(horizontal: false, vertical: true)

                // One tile per source, side by side.
                HStack(alignment: .top, spacing: 12) {
                    SoulseekTile(compact: true).frame(maxWidth: .infinity)
                    YouTubeTile().frame(maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)

                if total == 0 { GettingStarted() }

                section("Recently added", action: ("See all", { store.sidebar = .all })) {
                    Scroller(axis: .horizontal, indicators: false) {
                        LazyHStack(spacing: 14) {
                            ForEach(store.recentlyAdded) { r in RecentCard(row: r) }
                        }
                        .padding(.vertical, 4)
                    }
                }

                section("Playlists") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 196), spacing: 14)], spacing: 14) {
                        ForEach(store.library?.playlists ?? [], id: \.name) { p in PlaylistTile(playlist: p) }
                    }
                }
            }
            .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 30)
        }
    }

    private func section<C: View>(_ title: String, action: (String, () -> Void)? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                DotLabel(title, color: Theme.text2, size: 12)
                Spacer()
                if let action { Button(action.0, action: action.1).buttonStyle(.plain).font(Theme.ui(12.5, .semibold)).foregroundStyle(Theme.text2) }
            }
            content()
        }
    }
}

struct RecentCard: View {
    @EnvironmentObject var store: LibraryStore
    let row: Row
    @State private var hovering = false

    var body: some View {
        Button { store.focus = row.id } label: {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(row: row, size: 140, radius: 16)
                    .overlay(alignment: .topTrailing) { StatusDot(status: row.status, size: 18).padding(8) }
                Text(row.title).font(Theme.ui(13, .semibold)).lineLimit(1)
                Text(row.artist).font(Theme.ui(11.5)).foregroundStyle(Theme.text2).lineLimit(1)
                HStack(spacing: 6) {
                    BPMReadout(bpm: row.bestBPM, size: 12)
                    KeyBadge(camelot: row.camelot)
                }
            }
            .frame(width: 140, alignment: .leading)
            .padding(10)
            .glass(Theme.Radius.tile, shadow: hovering)
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct PlaylistTile: View {
    @EnvironmentObject var store: LibraryStore
    let playlist: LibraryPlaylist
    @State private var hovering = false

    var body: some View {
        let have = store.downloadedCount(playlist)
        let n = playlist.trackIDs.count
        let covers = playlist.trackIDs.prefix(4).compactMap { store.row($0) }
        Button { store.sidebar = .playlist(playlist.name) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                    GridRow { cover(covers, 0); cover(covers, 1) }
                    GridRow { cover(covers, 2); cover(covers, 3) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(playlist.name).font(Theme.ui(14, .semibold)).lineLimit(1)
                HStack {
                    Text(n == 1 ? "1 track" : "\(n) tracks").font(Theme.ui(11.5)).foregroundStyle(Theme.text2)
                    Spacer()
                    Text("\(have)/\(n)").font(Theme.dot(11)).foregroundStyle(Theme.text3)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.hairline)
                        Capsule().fill(Theme.lilac).frame(width: n > 0 ? max(3, g.size.width * Double(have) / Double(n)) : 0)
                    }
                }
                .frame(height: 3)
            }
            .padding(12)
            .glass(Theme.Radius.tile, shadow: hovering)
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private func cover(_ rows: [Row], _ i: Int) -> some View {
        if i < rows.count {
            ArtworkView(row: rows[i], size: 84, radius: 0)
        } else {
            Rectangle().fill(Theme.glassFill).frame(width: 84, height: 84)
        }
    }
}

/// Smart tile on Home: Soulseek sync status and start/stop.
struct SoulseekTile: View {
    @EnvironmentObject var store: LibraryStore
    var compact = false

    var body: some View {
        let s = store.soulseek
        if compact {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 17, weight: .regular)).foregroundStyle(Theme.smart)
                        .frame(width: 22, alignment: .leading)
                    DotLabel("Soulseek", color: Theme.text)
                    Spacer()
                    button(s)
                }
                Text(statusLine(s)).font(Theme.ui(12.5)).foregroundStyle(Theme.text2).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 22) { counter("Got", s.done); counter("Not found", s.notFound); counter("Failed", s.failed) }
            }
            .padding(16)
            .smartGlass(Theme.Radius.tile)
        } else {
            wide(s)
        }
    }

    @ViewBuilder private func button(_ s: SoulseekStatus) -> some View {
        if s.configured {
            PillButton(label: s.running ? "Stop" : "Start sync", icon: s.running ? "stop.fill" : "play.fill", style: s.running ? .glass : .smart) {
                s.running ? store.stopSoulseek() : DownloadGate.then { store.startSoulseek() }
            }
        } else {
            PillButton(label: "Set up", icon: "gearshape") { store.sidebar = .soulseek }
        }
    }

    private func wide(_ s: SoulseekStatus) -> some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: "arrow.down.to.line").font(.system(size: 24, weight: .regular)).foregroundStyle(Theme.smart)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                DotLabel("Soulseek", color: Theme.text)
                Text(statusLine(s)).font(Theme.ui(13)).foregroundStyle(Theme.text2).lineLimit(2)
            }
            Spacer()
            HStack(spacing: 18) {
                counter("Got", s.done)
                counter("Not found", s.notFound)
                counter("Failed", s.failed)
            }
            button(s)
        }
        .padding(18)
        .smartGlass(Theme.Radius.tile)
    }

    private func statusLine(_ s: SoulseekStatus) -> String {
        if !s.configured { return "Add your Soulseek login to start downloading missing tracks automatically." }
        if s.running { return s.recent.first.map { String($0.dropFirst(20)) } ?? "Starting…" }
        return "Downloads missing tracks in the best format available and files them into your crate."
    }

    private func counter(_ label: String, _ n: Int) -> some View { SyncCounter(label: label, n: n) }
}

/// Full Soulseek page: status, start/stop, setup help and the live log.
struct SoulseekView: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        let s = store.soulseek
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(eyebrow: "Sources", title: "Soulseek",
                       subtitle: s.running ? "Running — checks your playlists again every 30 minutes" : "Stopped") {
                if s.configured {
                    PillButton(label: s.running ? "Stop" : "Start sync", icon: s.running ? "stop.fill" : "play.fill", style: s.running ? .glass : .smart) {
                        s.running ? store.stopSoulseek() : DownloadGate.then { store.startSoulseek() }
                    }
                }
            }
            SoulseekTile()
            if !s.configured {
                VStack(alignment: .leading, spacing: 10) {
                    DotLabel("Setup", color: Theme.text)
                    SoulseekLogin()
                }
                .padding(18)
                .glass(Theme.Radius.tile)
            }
            LogPanel(lines: s.recent)
        }
        .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 10)
    }
}

/// Soulseek username + password (the same login SoulseekQt / Nicotine+ use; a new name is registered the first time
/// it signs in). Saved only on this Mac, in the helper's settings file.
struct SoulseekLogin: View {
    @EnvironmentObject var store: LibraryStore
    @State private var user = ""
    @State private var pass = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sign in to Soulseek — or pick a new username and password and one is made for you. It's saved only on this Mac.")
                .font(Theme.ui(13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Username", text: $user).textFieldStyle(.roundedBorder).frame(width: 200)
                SecureField("Password", text: $pass).textFieldStyle(.roundedBorder).frame(width: 200)
                PillButton(label: "Save", icon: "checkmark", style: .primary) { save() }.disabled(user.isEmpty || pass.isEmpty)
            }
        }
    }

    private func save() {
        let q = { (s: String) in "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let url = AppPaths.slskConfig
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? "[soulseek]\nusername = \"\"\npassword = \"\"\nlisten_port = 60000\nshare_dirs = []\n"
        for (key, value) in [("username", user), ("password", pass)] {
            let line = "\(key) = \(q(value))"
            if let r = text.range(of: "(?m)^\(key)\\s*=.*$", options: .regularExpression) { text.replaceSubrange(r, with: line) }
            else { text = text.replacingOccurrences(of: "[soulseek]\n", with: "[soulseek]\n\(line)\n") }
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        pass = ""
        store.refreshSoulseek()
    }
}

/// Home on a new Mac: how to get the first tracks in.
struct GettingStarted: View {
    @EnvironmentObject var store: LibraryStore
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DotLabel("Get started", color: Theme.text)
            Text("Add a playlist from a Spotify, YouTube or YouTube Music link — WreckBox finds every track, in the best quality it can (Soulseek FLAC first, then YouTube).")
                .font(Theme.ui(13.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                PillButton(label: "Add playlist", icon: "plus", style: .primary) { adding = true }
                PillButton(label: "Set up logins", icon: "person.crop.circle") { NotificationCenter.default.post(name: .showSetup, object: nil) }
                PillButton(label: "Search", icon: "magnifyingglass") { store.sidebar = .search }
                PillButton(label: "Friends' music", icon: "person.2") { store.sidebar = .friends }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .smartGlass(Theme.Radius.tile)
        .sheet(isPresented: $adding) { AddPlaylistSheet().environmentObject(store) }
    }
}
