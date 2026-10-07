import AppKit
import SwiftUI

// Developer tool: `djlib snapshot <out-dir>` renders the main screens to PNGs without opening a
// window, for checking the design. Blur materials and the web view don't render off-screen.

@MainActor
enum Snapshot {
    static func run(args: [String]) async {
        let out = URL(fileURLWithPath: args.first ?? "snapshots")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Theme.registerFonts()
        let store = LibraryStore()
        let browser = SoundCloudBrowser()
        store.refreshSoulseek()
        store.refreshYouTube()
        await store.refreshQuality()
        let firstWithFile = store.library?.tracks.first { store.state.tracks[$0.id]?.status == .downloaded }?.id
        let screens: [(String, SidebarItem, String?)] = [
            ("narrow-all-tracks", .all, firstWithFile), ("results", .results, nil),
            ("home", .home, nil), ("all-tracks", .all, firstWithFile), ("playlist", .playlist(store.library?.playlists.first?.name ?? ""), nil),
            ("soulseek", .soulseek, nil), ("youtube", .youtube, nil), ("search", .search, nil), ("files", .files, nil), ("queue", .queue, nil),
        ]
        for (name, item, focus) in screens {
            store.sidebar = item
            store.focus = focus
            if item == .queue {   // sample priorities, in memory only (never saved)
                store.state.downloadPriority = ["playlist:hard beatz", "genre:" + (store.genreCounts.first?.0 ?? "")]
            }
            let view = ContentView().environmentObject(store).environmentObject(browser)
                .environmentObject(PhoneSyncServer()).environmentObject(Updater()).environmentObject(RemoteAccess())
                .frame(width: name.hasPrefix("narrow") ? 1000 : 1440, height: name.hasPrefix("narrow") ? 660 : 900).preferredColorScheme(.dark)
                .environment(\.colorScheme, .dark).environment(\.snapshotMode, true)
            let r = ImageRenderer(content: view)
            r.scale = 1
            store.refreshSoulseek()
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: out.appendingPathComponent(name + ".png"))
                print("wrote \(name).png")
            }
        }
        // The player: visualisers with a sample spectrum, and the EQ panel.
        if let id = firstWithFile, let row = store.row(id) {
            let levels = LiveLevels<EmptyView>.estimate(12.3, bpm: 124, playing: true)
            let parts: [(String, AnyView)] = [
                ("player-matrix", AnyView(MatrixVisualizer(levels: levels).frame(width: 980, height: 420))),
                ("player-halo", AnyView(HaloVisualizer(levels: levels, row: row).frame(width: 600, height: 600))),
                ("player-eq", AnyView(EQPanel().padding(16).frame(width: 440))),
                ("add-playlist", AnyView(AddPlaylistSheet())),
                ("mini-player", AnyView(MiniPlayerView(previewDrawers: true).frame(width: MiniPlayerWindow.width, height: MiniPlayerWindow.body + MiniPlayerWindow.controlsHeight + MiniPlayerWindow.eqHeight - 2 * MiniPlayerWindow.tuck + 8).background(Color(red: 0.25, green: 0.3, blue: 0.4)))),
                ("player-bar", AnyView(VStack {
                    Spacer()
                    HStack(spacing: 14) {
                        ArtworkView(row: row, size: 44)
                        VStack(alignment: .leading) { Text(row.track.title).font(Theme.ui(13.5, .semibold)); Text(row.track.artists.joined(separator: ", ")).font(Theme.ui(12)).foregroundStyle(Theme.text2) }.frame(width: 220, alignment: .leading)
                        DotProgress(progress: 0.37) { _ in }
                    }.padding(.horizontal, 16).frame(height: 64).glass(Theme.Radius.tile)
                }.padding(22).frame(width: 1100, height: 120))),
            ]
            for (name, v) in parts {
                let r = ImageRenderer(content: v.environmentObject(store).background(Theme.bg).preferredColorScheme(.dark))
                r.scale = 1
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: out.appendingPathComponent(name + ".png"))
                    print("wrote \(name).png")
                }
            }
        }
    }
}
