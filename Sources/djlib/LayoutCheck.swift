import AppKit
import SwiftUI

// Developer tool: `djlib layout-check [width height]` hosts the real window content off-screen and
// reports every scroll view's frame vs. its content, to catch panels that can't scroll.

@MainActor
enum LayoutCheck {
    static func run(args: [String]) {
        let w = Double(args.first ?? "") ?? 1000, h = Double(args.dropFirst().first ?? "") ?? 640
        Theme.registerFonts()
        let store = LibraryStore()
        let focus = store.library?.tracks.first { store.state.tracks[$0.id]?.status == .downloaded }?.id
        let pages: [SidebarItem] = [.home, .all, .missing, .playlist(store.library?.playlists.first?.name ?? ""), .files, .queue, .results, .soulseek, .log]
        var problems = 0
        for page in pages {
        store.sidebar = page
        store.focus = focus
        let host = NSHostingView(rootView: ContentView().environmentObject(store).environmentObject(SoundCloudBrowser()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        func walk(_ v: NSView) {
            func nested(_ v: NSView) -> Bool { var p = v.superview; while let q = p { if q is NSScrollView { return true }; p = q.superview }; return false }
            if let s = v as? NSScrollView, !s.isHidden, !nested(s) {
                let f = s.convert(s.bounds, to: host)
                let visible = host.bounds
                if f.maxX > visible.maxX + 1 || f.maxY > visible.maxY + 1 || f.minX < -1 || f.minY < -1 {
                    problems += 1
                    print("✗ \(page): scroll view \(Int(f.width))x\(Int(f.height)) at (\(Int(f.minX)),\(Int(f.minY))) extends outside the \(Int(w))x\(Int(h)) window")
                }
            }
            v.subviews.forEach(walk)
        }
        walk(host)
        window.contentView = nil
        }
        print(problems == 0 ? "✓ \(Int(w))x\(Int(h)): every page's scroll areas fit inside the window" : "\(problems) problem(s) at \(Int(w))x\(Int(h))")
    }
}
