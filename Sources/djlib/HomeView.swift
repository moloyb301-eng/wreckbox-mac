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
                           subtitle: "\(total) tracks from \(store.library?.playlists.count ?? 0) Spotify playlists") {
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

                SoulseekTile()

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

    var body: some View {
        let s = store.soulseek
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: s.running ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.system(size: 30, weight: .light)).foregroundStyle(Theme.smart)
            VStack(alignment: .leading, spacing: 4) {
                DotLabel("Soulseek sync", color: Theme.text)
                Text(statusLine(s)).font(Theme.ui(13)).foregroundStyle(Theme.text2).lineLimit(2)
            }
            Spacer()
            HStack(spacing: 18) {
                counter("Got", s.done)
                counter("Not found", s.notFound)
                counter("Failed", s.failed)
            }
            if s.configured {
                PillButton(label: s.running ? "Stop" : "Start sync", icon: s.running ? "stop.fill" : "play.fill", style: s.running ? .glass : .smart) {
                    s.running ? store.stopSoulseek() : store.startSoulseek()
                }
            } else {
                PillButton(label: "Set up", icon: "gearshape") { store.sidebar = .soulseek }
            }
        }
        .padding(18)
        .smartGlass(Theme.Radius.tile)
    }

    private func statusLine(_ s: SoulseekStatus) -> String {
        if !s.configured { return "Add your Soulseek login to start downloading missing tracks automatically." }
        if s.running { return s.recent.first.map { String($0.dropFirst(20)) } ?? "Starting…" }
        return "Downloads missing tracks in the best format available and files them into your crate."
    }

    private func counter(_ label: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(n)").font(Theme.dot(20))
            DotLabel(label, size: 9)
        }
    }
}

/// Full Soulseek page: status, start/stop, setup help and the live log.
struct SoulseekView: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        let s = store.soulseek
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(eyebrow: "Tools", title: "Soulseek sync",
                       subtitle: s.running ? "Running — checks your playlists again every 30 minutes" : "Stopped") {
                if s.configured {
                    PillButton(label: s.running ? "Stop" : "Start sync", icon: s.running ? "stop.fill" : "play.fill", style: s.running ? .glass : .smart) {
                        s.running ? store.stopSoulseek() : store.startSoulseek()
                    }
                }
            }
            SoulseekTile()
            if !s.configured {
                VStack(alignment: .leading, spacing: 10) {
                    DotLabel("Setup", color: Theme.text)
                    Text("Open the settings file, fill in your Soulseek username and password, save, and come back here.")
                        .font(Theme.ui(13)).foregroundStyle(Theme.text2)
                    PillButton(label: "Open config.toml", icon: "doc.text", style: .primary) {
                        NSWorkspace.shared.open([AppPaths.slskConfig], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                                configuration: NSWorkspace.OpenConfiguration())
                    }
                }
                .padding(18)
                .glass(Theme.Radius.tile)
            }
            VStack(alignment: .leading, spacing: 10) {
                DotLabel("Log")
                Scroller {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if s.recent.isEmpty { Text("No activity yet.").foregroundStyle(Theme.text3) }
                        ForEach(Array(s.recent.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(color(line)).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(18)
            .glass(Theme.Radius.card)
        }
        .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 10)
    }

    private func color(_ line: String) -> Color {
        if line.contains("✓") { return Theme.lilac }
        if line.contains("✗") || line.contains("failed") { return Theme.peach }
        return Theme.text2
    }
}
