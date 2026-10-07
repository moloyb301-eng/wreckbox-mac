import AppKit
import SwiftUI

// The desktop mini player: a chrome, skinned player in the spirit of Sonique / K-Jofol that lives on the desktop
// (or floats above windows), with a dot-matrix LCD and two drawers that slide out underneath — controls + up next,
// and the EQ. It controls whichever device is playing, like the now-playing bar.

@MainActor
final class MiniPlayerWindow {
    static let shared = MiniPlayerWindow()
    private var window: NSWindow?
    static let width: CGFloat = 470, body: CGFloat = 176
    /// Drawer heights; each tucks `tuck` points under the one above it.
    static let controlsHeight: CGFloat = 150, eqHeight: CGFloat = 232, tuck: CGFloat = 30

    var isOpen: Bool { window?.isVisible == true }

    /// Desktop level (under other windows, on every Space) or floating above them.
    var onDesktop: Bool {
        get { UserDefaults.standard.object(forKey: "miniOnDesktop") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "miniOnDesktop"); applyLevel() }
    }

    func toggle(store: LibraryStore) { isOpen ? close() : open(store: store) }

    func open(store: LibraryStore) {
        UserDefaults.standard.set(true, forKey: "miniOpen")
        if let w = window { w.orderFrontRegardless(); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.body),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: MiniPlayerView().environmentObject(store))
        if let saved = UserDefaults.standard.string(forKey: "miniFrame") {
            w.setFrameTopLeftPoint(NSPointFromString(saved))
        } else if let s = NSScreen.main?.visibleFrame {
            w.setFrameTopLeftPoint(NSPoint(x: s.maxX - Self.width - 40, y: s.maxY - 40))
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: w, queue: .main) { _ in
            let f = w.frame
            UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: f.minX, y: f.maxY)), forKey: "miniFrame")
        }
        window = w
        applyLevel()
        w.orderFrontRegardless()
    }

    func close() {
        UserDefaults.standard.set(false, forKey: "miniOpen")
        window?.orderOut(nil)
    }

    /// Opened drawers change the height; the top edge stays where it is.
    func resize(controls: Bool, eq: Bool) {
        guard let w = window else { return }
        let h = Self.body + (controls ? Self.controlsHeight - Self.tuck : 0) + (eq ? Self.eqHeight - Self.tuck : 0) + 8
        var f = w.frame
        f.origin.y = f.maxY - h
        f.size.height = h
        w.setFrame(f, display: true, animate: true)
    }

    private func applyLevel() {
        guard let w = window else { return }
        if onDesktop {
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        } else {
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
    }
}

// MARK: - Look

enum Chrome {
    static let body = LinearGradient(stops: [
        .init(color: Color(white: 0.96), location: 0), .init(color: Color(white: 0.74), location: 0.35),
        .init(color: Color(white: 0.88), location: 0.55), .init(color: Color(white: 0.56), location: 1),
    ], startPoint: .top, endPoint: .bottom)
    static let rim = LinearGradient(colors: [.white.opacity(0.95), Color(white: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let dark = LinearGradient(colors: [Color(white: 0.30), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
    static let lcd = Color(red: 0.035, green: 0.04, blue: 0.06)
    static let ink = Color(white: 0.18)
}

/// A pressed-metal button: chrome pill with an engraved icon.
struct ChromeButton: View {
    let icon: String
    var width: CGFloat = 40
    var height: CGFloat = 26
    var lit = false
    let action: () -> Void
    @State private var down = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Capsule().fill(down ? Chrome.dark : Chrome.body)
                Capsule().strokeBorder(Chrome.rim, lineWidth: 1.2)
                Image(systemName: icon).font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(lit ? Theme.lilac : down ? Color.white.opacity(0.85) : Chrome.ink)
                    .shadow(color: .white.opacity(down ? 0 : 0.7), radius: 0, y: 1)
            }
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1.5)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in down = true }.onEnded { _ in down = false })
    }
}

/// The chassis: a jog disc on the left fused to a rounded body.
struct ChassisShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let d = r.height
        p.addEllipse(in: CGRect(x: r.minX, y: r.minY, width: d, height: d))
        p.addRoundedRect(in: CGRect(x: r.minX + d * 0.55, y: r.minY + d * 0.12, width: r.width - d * 0.55, height: d * 0.76),
                         cornerSize: CGSize(width: d * 0.24, height: d * 0.24))
        return p
    }
}

// MARK: - View

struct MiniPlayerView: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject var playback = Playback.shared
    @State private var controlsOpen = false
    @State private var eqOpen = false
    var previewDrawers = false   // snapshots: both drawers open

    init(previewDrawers: Bool = false) {
        self.previewDrawers = previewDrawers
        _controlsOpen = State(initialValue: previewDrawers)
        _eqOpen = State(initialValue: previewDrawers)
    }

    var body: some View {
        let d = playback.active ?? playback.deviceList.first
        let row = d?.trackID.flatMap { store.row($0) }
        VStack(spacing: -MiniPlayerWindow.tuck) {
            chassis(d, row).frame(width: MiniPlayerWindow.width, height: MiniPlayerWindow.body)
                .zIndex(2)
            if controlsOpen {
                drawer(height: MiniPlayerWindow.controlsHeight) { controlsDrawer(d) }
                    .transition(.move(edge: .top).combined(with: .opacity)).zIndex(1)
            }
            if eqOpen {
                drawer(height: MiniPlayerWindow.eqHeight) { EQPanel(compact: true).environment(\.colorScheme, .dark) }
                    .transition(.move(edge: .top).combined(with: .opacity)).zIndex(0)
            }
            Spacer(minLength: 0)
        }
        .frame(width: MiniPlayerWindow.width, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: controlsOpen) { _ in resize() }
        .onChange(of: eqOpen) { _ in resize() }
    }

    private func resize() { MiniPlayerWindow.shared.resize(controls: controlsOpen, eq: eqOpen) }

    // The chrome body: jog disc with play/pause, LCD, transport, drawer tabs.
    private func chassis(_ d: DeviceState?, _ row: Row?) -> some View {
        let disc: CGFloat = MiniPlayerWindow.body - 12
        return ZStack(alignment: .topLeading) {
            ChassisShape().fill(Chrome.body)
                .overlay(ChassisShape().stroke(Chrome.rim, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.45), radius: 10, y: 6)
                .padding(6)
            // Jog disc: volume dots around a dark well, play/pause in the middle.
            ZStack {
                Circle().fill(Chrome.dark).frame(width: disc * 0.72, height: disc * 0.72)
                    .overlay(Circle().strokeBorder(Chrome.rim, lineWidth: 2))
                VolumeDots(volume: d?.volume ?? 1, radius: disc * 0.43) { v in playback.control(.volume, value: v) }
                Button { playback.control(.toggle) } label: {
                    ZStack {
                        Circle().fill(Chrome.body).frame(width: disc * 0.42, height: disc * 0.42)
                            .overlay(Circle().strokeBorder(Chrome.rim, lineWidth: 1.5))
                            .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                        Image(systemName: d?.playing == true ? "pause.fill" : "play.fill").font(.system(size: 18, weight: .heavy))
                            .foregroundStyle(Chrome.ink)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(width: disc, height: disc)
            .padding(6)
            // Body: LCD + transport + tabs.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Spacer()
                    tinyButton(MiniPlayerWindow.shared.onDesktop ? "pin.fill" : "pin.slash",
                               MiniPlayerWindow.shared.onDesktop ? "On the desktop — click to float above windows" : "Floating — click to keep it on the desktop") {
                        MiniPlayerWindow.shared.onDesktop.toggle()
                        playback.objectWillChange.send()
                    }
                    tinyButton("arrow.up.left.square", "Open WreckBox") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.styleMask.contains(.titled) }?.makeKeyAndOrderFront(nil) }
                    tinyButton("xmark", "Close the mini player") { MiniPlayerWindow.shared.close() }
                }
                LCD(d: d, row: row)
                HStack(spacing: 6) {
                    ChromeButton(icon: "backward.fill") { playback.control(.previous) }
                    ChromeButton(icon: "stop.fill") { playback.control(.pause); playback.control(.seek, value: 0) }
                    ChromeButton(icon: "forward.fill") { playback.control(.next) }
                    Spacer()
                    ChromeButton(icon: "music.note.list", width: 44, lit: controlsOpen) { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { controlsOpen.toggle() } }
                        .help("Controls drawer: position, volume, device, up next")
                    ChromeButton(icon: "slider.vertical.3", width: 44, lit: eqOpen) { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { eqOpen.toggle() } }
                        .help("EQ drawer")
                }
            }
            .padding(.leading, disc + 2)
            .padding(.trailing, 26)
            .padding(.top, 20)
        }
    }

    private func tinyButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 8.5, weight: .heavy)).foregroundStyle(Chrome.ink).frame(width: 16, height: 14)
                .background(Capsule().fill(Chrome.body)).overlay(Capsule().strokeBorder(Chrome.rim, lineWidth: 0.8))
        }
        .buttonStyle(.plain).help(help)
    }

    /// A chrome tray under the body; the content sits on a dark glass panel.
    /// The top `tuck` points slide under the part above, so the tray looks like it pulls out of the body.
    private func drawer<C: View>(height: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Chrome.lcd))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(0.8), lineWidth: 1.5))
            .padding(.horizontal, 10).padding(.bottom, 10)
            .padding(.top, MiniPlayerWindow.tuck + 4)
            .background(RoundedRectangle(cornerRadius: 20).fill(Chrome.body).overlay(RoundedRectangle(cornerRadius: 20).stroke(Chrome.rim, lineWidth: 1.2)))
            .frame(width: MiniPlayerWindow.width - 150, height: height)
            .padding(.leading, 120)
            .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
    }

    private func controlsDrawer(_ d: DeviceState?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(NowPlayingBar.time(d?.livePosition ?? 0)).font(Theme.dot(10)).foregroundStyle(Theme.text3)
                DotProgress(progress: (d?.duration ?? 0) > 0 ? (d!.livePosition / d!.duration) : 0) { f in playback.control(.seek, value: f * (d?.duration ?? 0)) }
                Text(NowPlayingBar.time(d?.duration ?? 0)).font(Theme.dot(10)).foregroundStyle(Theme.text3)
            }
            HStack {
                DotLabel("Up next", color: Theme.text)
                Spacer()
                DevicePicker(playback: playback)
            }
            let q = d?.queue ?? [], i = d?.index ?? -1
            ForEach(Array(q.dropFirst(max(0, i + 1)).prefix(5).enumerated()), id: \.offset) { n, id in
                HStack(spacing: 8) {
                    Text(String(format: "%02d", n + 1)).font(Theme.dot(10)).foregroundStyle(Theme.lilac)
                    Text(store.describe(id)).font(Theme.ui(11.5)).foregroundStyle(Theme.text2).lineLimit(1)
                }
            }
            if q.count <= i + 1 { Text("Nothing queued after this one.").font(Theme.ui(11.5)).foregroundStyle(Theme.text3) }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Twelve dots round the jog disc: how loud. Click a dot to set the volume.
struct VolumeDots: View {
    let volume: Double
    let radius: CGFloat
    let set: (Double) -> Void
    var body: some View {
        ZStack {
            ForEach(0..<12, id: \.self) { i in
                let a = Double(i) / 12 * 2 * .pi * 0.75 + .pi * 0.75     // a 270° arc, bottom gap
                let on = Double(i + 1) / 12 <= volume + 0.001
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(on ? MatrixVisualizer.color(Double(i) / 11) : Color.black.opacity(0.35))
                    .frame(width: 6, height: 6)
                    .shadow(color: on ? MatrixVisualizer.color(Double(i) / 11).opacity(0.8) : .clear, radius: 3)
                    .offset(x: cos(a) * radius, y: sin(a) * radius)
                    .onTapGesture { set(Double(i + 1) / 12) }
            }
        }
    }
}

/// The screen: scrolling title, time, format, a 16-band dot spectrum.
struct LCD: View {
    let d: DeviceState?
    let row: Row?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Marquee(text: row.map { "\($0.track.artists.joined(separator: ", ")) — \($0.track.title)" } ?? "WRECKBOX · NOTHING PLAYING")
                    .frame(height: 14)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(NowPlayingBar.time(d?.livePosition ?? 0)).font(Theme.dot(26)).foregroundStyle(Theme.peach)
                        .shadow(color: Theme.peach.opacity(0.6), radius: 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.map { $0.playing ? "PLAY" : "PAUSE" } ?? "STOP").font(Theme.dot(9)).foregroundStyle(Theme.lilac)
                        Text(d?.kind == "phone" ? "ON PHONE" : "THIS MAC").font(Theme.dot(9)).foregroundStyle(Theme.text3)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            LiveLevels(local: d?.id == Playback.shared.selfID, bpm: row?.bestBPM ?? 120, playing: d?.playing == true) { levels in
                MatrixVisualizer(levels: stride(from: 0, to: levels.count, by: 2).map { max(levels[$0], levels[min($0 + 1, levels.count - 1)]) }, rows: 8)
            }
            .frame(width: 110, height: 52)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Chrome.lcd))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LinearGradient(colors: [.black, Color(white: 0.5)], startPoint: .top, endPoint: .bottom), lineWidth: 2))
    }
}

/// Text that scrolls when it doesn't fit, like an old player's display.
struct Marquee: View {
    let text: String
    var body: some View {
        GeometryReader { g in
            let w = CGFloat(text.count) * 7.2
            let travel = max(0, w - g.size.width + 30)
            TimelineView(.animation(minimumInterval: 1 / 20, paused: travel == 0)) { t in
                let x = travel == 0 ? 0 : -CGFloat(t.date.timeIntervalSinceReferenceDate * 22).truncatingRemainder(dividingBy: w + 40)
                HStack(spacing: 40) {
                    Text(text.uppercased())
                    if travel > 0 { Text(text.uppercased()) }
                }
                .font(Theme.dot(11)).foregroundStyle(Theme.lilac).fixedSize()
                .offset(x: x)
            }
            .frame(width: g.size.width, alignment: .leading)
            .clipped()
        }
    }
}
