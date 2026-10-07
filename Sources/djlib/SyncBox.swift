import SwiftUI

/// Small box under the logo: is anything syncing, and from where. Click for each source's status.
struct SyncBox: View {
    @EnvironmentObject var store: LibraryStore
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        let total = store.library?.tracks.count ?? 0
        let have = store.count(.downloaded)
        let sources = [store.soulseek.running ? "Soulseek" : nil, store.youtube.running ? "YouTube" : nil].compactMap { $0 }
        Button { open.toggle() } label: {
            HStack(spacing: 0) {
                DotGrid(progress: total > 0 ? Double(have) / Double(total) : 0)
                    .frame(width: SideItem.iconWidth, alignment: .center)
                VStack(alignment: .leading, spacing: 1) {
                    Text(sources.isEmpty ? "Sync paused" : "Syncing").font(Theme.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                    Text(sources.isEmpty ? "\(have) of \(total) in your crate" : sources.joined(separator: " · "))
                        .font(Theme.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                .padding(.leading, 10)
                Spacer(minLength: 6)
                if !sources.isEmpty { Circle().fill(Theme.smart).frame(width: 6, height: 6).frame(width: SideItem.indicatorWidth) }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text3)
                    .frame(width: 14)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering || open ? Theme.hover : Theme.glassFill)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $open, arrowEdge: .trailing) { SyncPanel().environmentObject(store) }
    }
}

/// Status of every source: Spotify playlists, Soulseek, YouTube.
struct SyncPanel: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        let s = store.soulseek, y = store.youtube
        VStack(alignment: .leading, spacing: 0) {
            DotLabel("Sync", color: Theme.text).padding(.bottom, 10)
            row(icon: "music.note.list", name: "Spotify playlists",
                status: store.busy?.contains("Spotify") == true ? "Syncing now…" : PlaylistSync.lastSync.map { "Last synced \($0.formatted(.relative(presentation: .named))) · every morning at 7:00" } ?? "Not synced yet",
                counts: nil, live: store.busy?.contains("Spotify") == true) {
                PillButton(label: "Sync now", icon: "arrow.triangle.2.circlepath") { Task { await store.syncPlaylists() } }
                    .disabled(store.busy != nil)
            }
            Divider().overlay(Theme.hairline).padding(.vertical, 10)
            row(icon: "arrow.down.to.line", name: "Soulseek",
                status: s.running ? (s.recent.first.map { String($0.dropFirst(20)) } ?? "Running") : (s.configured ? "Stopped" : "Not set up"),
                counts: "\(s.done) got · \(s.notFound) not found · \(s.failed) failed", live: s.running) {
                if s.configured {
                    PillButton(label: s.running ? "Stop" : "Start", icon: s.running ? "stop.fill" : "play.fill") {
                        s.running ? store.stopSoulseek() : DownloadGate.then { store.startSoulseek() }
                    }
                }
            }
            Divider().overlay(Theme.hairline).padding(.vertical, 10)
            row(icon: "play.rectangle", name: "YouTube", status: YouTubeTile.statusLine(y),
                counts: "\(y.done) got · \(y.notFound) not on YouTube · \(y.failed) failed", live: y.running) {
                PillButton(label: y.running ? "Turn off" : "Turn on", icon: y.running ? "stop.fill" : "play.fill") {
                    y.running ? store.stopYouTubeFill() : DownloadGate.then { store.startYouTubeFill() }
                }
            }
        }
        .padding(18)
        .frame(width: 420)
        .background(Theme.bg)
    }

    private func row<B: View>(icon: String, name: String, status: String, counts: String?, live: Bool, @ViewBuilder button: () -> B) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text2)
                .frame(width: SideItem.iconWidth, alignment: .center).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).font(Theme.ui(13, .semibold)).foregroundStyle(Theme.text)
                    if live { Circle().fill(Theme.smart).frame(width: 6, height: 6) }
                }
                Text(status).font(Theme.ui(11.5)).foregroundStyle(Theme.text2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let counts { Text(counts).font(Theme.ui(11)).foregroundStyle(Theme.text3) }
            }
            .padding(.leading, 10)
            Spacer(minLength: 10)
            button()
        }
    }
}
