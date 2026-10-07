import AppKit
import SwiftUI

// Full-screen player, EQ panel and the dot-matrix visualisers. Drawn with Canvas (no layers per dot, no blur
// animations): a frame is one pass over ~600 rounded squares, redrawn only when the spectrum changes (~30 Hz).

// MARK: - Visualiser

enum VisualMode: String, CaseIterable { case art = "Album art", matrix = "Matrix", halo = "Halo" }

/// Spectrum levels for whatever plays: this Mac's real audio, or — when a phone plays — a beat-synced estimate
/// from the track's BPM and energy (the phone's audio doesn't come through this Mac).
struct LiveLevels<Content: View>: View {
    @ObservedObject var spectrum = Spectrum.shared
    let local: Bool
    let bpm: Double
    let playing: Bool
    @ViewBuilder let content: ([Float]) -> Content

    var body: some View {
        if local {
            content(spectrum.levels)
                .onAppear { Playback.shared.audio.spectrum(true) }
                .onDisappear { Playback.shared.audio.spectrum(false) }
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { t in
                content(Self.estimate(t.date.timeIntervalSinceReferenceDate, bpm: bpm, playing: playing))
            }
        }
    }

    static func estimate(_ t: Double, bpm: Double, playing: Bool) -> [Float] {
        guard playing else { return .init(repeating: 0, count: Spectrum.bands) }
        let beat = t * max(bpm, 60) / 60
        let kick = Float(pow(max(0, cos(beat * .pi * 2)), 6))
        return (0..<Spectrum.bands).map { b in
            let f = Float(b) / Float(Spectrum.bands)
            let wobble = Float(0.5 + 0.5 * sin(t * (1.3 + Double(b) * 0.37) + Double(b)))
            return max(0, min(1, (1 - f) * 0.55 * kick + 0.25 * wobble * (1 - f * 0.6) + 0.08))
        }
    }
}

/// LED columns: lilac at the bottom to peach at the top, a peak dot that falls slowly, a faint reflection.
struct MatrixVisualizer: View {
    let levels: [Float]
    var rows = 18
    @State private var peaks = [Float](repeating: 0, count: Spectrum.bands)

    var body: some View {
        Canvas { ctx, size in
            let cols = levels.count
            let gap: CGFloat = 3
            let cell = min((size.width - gap * CGFloat(cols - 1)) / CGFloat(cols), (size.height * 0.78 - gap * CGFloat(rows - 1)) / CGFloat(rows))
            let width = cell * CGFloat(cols) + gap * CGFloat(cols - 1)
            let x0 = (size.width - width) / 2
            let floor = size.height * 0.78
            for c in 0..<cols {
                let lit = Int((CGFloat(levels[c]) * CGFloat(rows)).rounded())
                let peak = Int((CGFloat(peaks[c]) * CGFloat(rows)).rounded())
                let x = x0 + CGFloat(c) * (cell + gap)
                for r in 0..<rows {
                    let y = floor - CGFloat(r + 1) * cell - CGFloat(r) * gap
                    let rect = CGRect(x: x, y: y, width: cell, height: cell)
                    let on = r < lit || (r == peak - 1 && peak > 0)
                    let color = on ? Self.color(Double(r) / Double(rows - 1)) : Color.white.opacity(0.05)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: cell * 0.22), with: .color(color))
                    // Reflection: the lowest rows mirrored under the floor, fading out.
                    if r < 5, r < lit {
                        let ry = floor + gap + CGFloat(r) * (cell + gap)
                        ctx.fill(Path(roundedRect: CGRect(x: x, y: ry, width: cell, height: cell), cornerRadius: cell * 0.22),
                                 with: .color(color.opacity(0.22 - Double(r) * 0.04)))
                    }
                }
            }
        }
        .onChange(of: levels) { new in
            for i in peaks.indices { peaks[i] = new[i] >= peaks[i] ? new[i] : max(new[i], peaks[i] - 0.018) }
        }
    }

    static func color(_ h: Double) -> Color {
        // lilac → light blue → peach, like the app's "smart" gradient.
        let a = (r: 0.733, g: 0.588, b: 0.855), m = (r: 0.663, g: 0.784, b: 0.941), z = (r: 0.937, g: 0.686, b: 0.525)
        let (p, q, t) = h < 0.5 ? (a, m, h * 2) : (m, z, (h - 0.5) * 2)
        return Color(red: p.r + (q.r - p.r) * t, green: p.g + (q.g - p.g) * t, blue: p.b + (q.b - p.b) * t)
    }
}

/// The cover in the middle, dot rays around it that stretch with the music.
struct HaloVisualizer: View {
    let levels: [Float]
    let row: Row

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            let art = side * 0.46
            ZStack {
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let rays = levels.count * 2          // mirrored: low end at the top, both sides
                    let r0 = art / 2 + 14, dot = max(3, side / 110), steps = 9
                    for i in 0..<rays {
                        let b = i < levels.count ? i : rays - 1 - i
                        let a = Double(i) / Double(rays) * 2 * .pi - .pi / 2
                        let lit = Int((CGFloat(levels[b]) * CGFloat(steps)).rounded())
                        for s in 0..<steps {
                            let rr = r0 + CGFloat(s) * (dot + 4)
                            let p = CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
                            let on = s < lit
                            let color = on ? MatrixVisualizer.color(Double(s) / Double(steps - 1)) : Color.white.opacity(0.045)
                            ctx.fill(Path(roundedRect: CGRect(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot), cornerRadius: dot * 0.25),
                                     with: .color(color))
                        }
                    }
                }
                ArtworkView(row: row, size: art, radius: art / 2)
                    .scaleEffect(1 + CGFloat(levels.prefix(4).max() ?? 0) * 0.035)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

// MARK: - EQ panel

/// Presets, on/off, and ten dot-column sliders (drag up/down).
struct EQPanel: View {
    @ObservedObject var eq = EQ.shared
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack(spacing: 8) {
                DotLabel("Equaliser", color: Theme.text)
                Spacer()
                Toggle("", isOn: $eq.on).toggleStyle(.switch).labelsHidden().controlSize(.mini)
                    .help(eq.on ? "EQ on" : "EQ off (bypassed)")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(EQ.presets, id: \.0) { p in
                        Button { eq.choose(p.0) } label: {
                            Text(p.0).font(Theme.ui(11.5, .semibold)).padding(.horizontal, 9).padding(.vertical, 4)
                                .foregroundStyle(eq.preset == p.0 ? Color.black : Theme.text2)
                                .background(Capsule().fill(eq.preset == p.0 ? Color.white : Theme.glassFill))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: compact ? 6 : 10) {
                ForEach(0..<EQ.frequencies.count, id: \.self) { i in
                    VStack(spacing: 5) {
                        Text(String(format: "%+.0f", eq.gains[i])).font(Theme.dot(9)).foregroundStyle(Theme.text3)
                        DotSlider(value: Binding(get: { eq.gains[i] }, set: { eq.set(i, $0) }), dots: compact ? 13 : 19)
                            .opacity(eq.on ? 1 : 0.35)
                        Text(EQ.labels[i]).font(Theme.dot(9)).foregroundStyle(Theme.text3)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// A vertical column of dots from -12 to +12 dB; lit from the centre line to the value.
struct DotSlider: View {
    @Binding var value: Float
    var dots = 19
    var body: some View {
        GeometryReader { g in
            let mid = dots / 2
            let level = Int((value / 12 * Float(mid)).rounded())
            VStack(spacing: 0) {
                ForEach(0..<dots, id: \.self) { i in
                    let k = mid - i                                     // +mid at the top … -mid at the bottom
                    let on = (level > 0 && k > 0 && k <= level) || (level < 0 && k < 0 && k >= level) || k == 0
                    RoundedRectangle(cornerRadius: 1.2)
                        .fill(k == 0 ? Theme.text3 : on ? MatrixVisualizer.color(Double(i) / Double(dots - 1)).opacity(1) : Color.white.opacity(0.07))
                        .frame(width: 6, height: 4)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: g.size.width)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let f = 1 - min(1, max(0, v.location.y / g.size.height))   // 0 bottom … 1 top
                value = Float(((f * 24 - 12) * 2).rounded() / 2)
            })
            .onTapGesture(count: 2) { value = 0 }
        }
        .frame(height: CGFloat(dots) * 7)
        .help("Drag to set; double-click for 0 dB")
    }
}

// MARK: - Full-screen player

struct FullPlayerView: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject var playback = Playback.shared
    @AppStorage("visualMode") private var mode = VisualMode.matrix.rawValue
    @State private var showEQ = false

    var body: some View {
        let d = playback.active
        let row = d?.trackID.flatMap { store.row($0) }
        ZStack {
            AmbientBackground(row: row).overlay(Color.black.opacity(0.35))
            VStack(spacing: 22) {
                HStack {
                    Picker("", selection: $mode) {
                        ForEach(VisualMode.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                    Spacer()
                    PillButton(label: "EQ", icon: "slider.vertical.3", style: showEQ ? .primary : .glass) { withAnimation(.spring(response: 0.3)) { showEQ.toggle() } }
                    PillButton(label: "Exit full screen", icon: "arrow.down.right.and.arrow.up.left") { playback.setFullScreen(false) }
                        .keyboardShortcut(.escape, modifiers: [])
                }
                if let d, let row {
                    Group {
                        switch VisualMode(rawValue: mode) ?? .matrix {
                        case .art: ArtworkView(row: row, size: 440, radius: 18).shadow(color: .black.opacity(0.5), radius: 40, y: 20)
                        case .matrix:
                            LiveLevels(local: d.id == playback.selfID, bpm: row.bestBPM ?? 120, playing: d.playing) { MatrixVisualizer(levels: $0) }
                                .frame(maxWidth: 980)
                        case .halo:
                            LiveLevels(local: d.id == playback.selfID, bpm: row.bestBPM ?? 120, playing: d.playing) { HaloVisualizer(levels: $0, row: row) }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 6) {
                        Text(row.track.title).font(Theme.ui(30, .semibold)).lineLimit(1)
                        Text(row.track.artists.joined(separator: ", ")).font(Theme.ui(16)).foregroundStyle(Theme.text2).lineLimit(1)
                        if d.id != playback.selfID {
                            Text("Playing on \(d.name)").font(Theme.ui(12.5, .semibold)).foregroundStyle(Theme.lilac)
                        }
                    }
                    HStack(spacing: 14) {
                        Text(NowPlayingBar.time(d.livePosition)).font(Theme.dot(12)).foregroundStyle(Theme.text3).frame(width: 48, alignment: .trailing)
                        DotProgress(progress: d.duration > 0 ? d.livePosition / d.duration : 0) { playback.control(.seek, value: $0 * d.duration) }
                        Text(NowPlayingBar.time(d.duration)).font(Theme.dot(12)).foregroundStyle(Theme.text3).frame(width: 48, alignment: .leading)
                    }
                    .frame(maxWidth: 760)
                    HStack(spacing: 18) {
                        bigButton("shuffle", lit: playback.activeShuffle) { playback.control(.shuffle) }
                        bigButton("backward.fill") { playback.control(.previous) }
                        Button { playback.control(.toggle) } label: {
                            Image(systemName: d.playing ? "pause.fill" : "play.fill").font(.system(size: 22, weight: .bold))
                                .frame(width: 84, height: 50).foregroundStyle(.black).background(Capsule().fill(.white))
                        }
                        .buttonStyle(.plain).keyboardShortcut(.space, modifiers: [])
                        bigButton("forward.fill") { playback.control(.next) }
                        DevicePicker(playback: playback).padding(.leading, 12)
                    }
                    if showEQ {
                        EQPanel().padding(18).frame(maxWidth: 620).glass(Theme.Radius.tile)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                } else {
                    EmptyState(icon: "music.note", text: "Nothing playing. Double-click a track to play it.")
                }
            }
            .padding(36)
        }
    }

    private func bigButton(_ icon: String, lit: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).frame(width: 54, height: 50)
                .foregroundStyle(lit ? Theme.lilac : Theme.text).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
