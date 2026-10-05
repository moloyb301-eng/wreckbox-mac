import AppKit
import SwiftUI

// Developer tool: `djlib snapshot <out-dir>` renders the main screens to PNGs without opening a
// window, for checking the design. Blur materials and the web view don't render off-screen.

@MainActor
enum Snapshot {
    static func run(args: [String]) {
        let out = URL(fileURLWithPath: args.first ?? "snapshots")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Theme.registerFonts()
        let store = LibraryStore()
        let browser = SoundCloudBrowser()
        let firstWithFile = store.library?.tracks.first { store.state.tracks[$0.id]?.status == .downloaded }?.id
        let screens: [(String, SidebarItem, String?)] = [
            ("home", .home, nil), ("all-tracks", .all, firstWithFile), ("playlist", .playlist(store.library?.playlists.first?.name ?? ""), nil),
            ("soulseek", .soulseek, nil), ("files", .files, nil),
        ]
        for (name, item, focus) in screens {
            store.sidebar = item
            store.focus = focus
            let view = ContentView().environmentObject(store).environmentObject(browser)
                .frame(width: 1440, height: 900).preferredColorScheme(.dark)
                .environment(\.colorScheme, .dark).environment(\.snapshotMode, true)
            let r = ImageRenderer(content: view)
            r.scale = 1
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: out.appendingPathComponent(name + ".png"))
                print("wrote \(name).png")
            }
        }
    }
}
