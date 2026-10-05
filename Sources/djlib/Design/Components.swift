import SwiftUI

// Reusable pieces of the DJ Library design: dot-matrix labels, chips, pill buttons, status
// circles, BPM / key / energy readouts, album art and the ambient art background.

/// Small uppercase dot-matrix section label.
struct DotLabel: View {
    let text: String
    var color: Color = Theme.text3
    var size: CGFloat = 11

    init(_ text: String, color: Color = Theme.text3, size: CGFloat = 11) {
        self.text = text; self.color = color; self.size = size
    }

    var body: some View {
        Text(text.uppercased()).font(Theme.dot(size)).tracking(1.6).foregroundStyle(color)
    }
}

/// Capsule filter chip. Selected: white pill with a lilac dot.
struct Chip: View {
    let label: String
    var count: Int?
    var selected = false
    var smart = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if selected { Circle().fill(Theme.lilac).frame(width: 6, height: 6) }
                Text(label).font(Theme.ui(12.5, .semibold)).lineLimit(1)
                if let count {
                    Text("\(count)").font(Theme.dot(11)).opacity(0.6)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6.5)
            .fixedSize()
            .foregroundStyle(selected ? Color.black : smart ? Theme.text : Theme.text2)
            .background {
                if selected { Capsule().fill(.white) }
                else if smart { Capsule().fill(Theme.smart.opacity(0.22)).overlay(Capsule().strokeBorder(Theme.smart.opacity(0.6))) }
                else { Capsule().fill(Theme.glassFill).overlay(Capsule().strokeBorder(Theme.hairline)) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Pill-shaped action button.
struct PillButton: View {
    enum Style { case glass, primary, smart }
    let label: String
    var icon: String?
    var style: Style = .glass
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
                Text(label).font(Theme.ui(13, .semibold))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(style == .primary ? Color.black : Theme.text)
            .background {
                switch style {
                case .primary: Capsule().fill(.white)
                case .smart: Capsule().fill(Theme.smart.opacity(0.28)).overlay(Capsule().strokeBorder(Theme.smart.opacity(0.7)))
                case .glass: Capsule().fill(Theme.glassFill).overlay(Capsule().strokeBorder(Theme.hairline))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Round icon-only glass button.
struct RoundButton: View {
    let icon: String
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.glassFill).overlay(Circle().strokeBorder(Theme.hairline)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Have / missing / ignored, drawn like the design's checklist circle.
struct StatusDot: View {
    let status: TrackStatus
    var size: CGFloat = 16

    var body: some View {
        switch status {
        case .downloaded:
            Circle().fill(Theme.lilac).frame(width: size, height: size)
                .overlay(Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .heavy)).foregroundStyle(.black))
        case .missing:
            Circle().strokeBorder(Theme.text3, style: StrokeStyle(lineWidth: 1.3, dash: [2.5, 2.5])).frame(width: size, height: size)
        case .ignored:
            Image(systemName: "nosign").font(.system(size: size * 0.8)).foregroundStyle(Theme.text3).frame(width: size, height: size)
        }
    }
}

/// BPM in dot-matrix; "?" when the tempo is uncertain.
struct BPMReadout: View {
    let bpm: Double?
    var unsure = false
    var size: CGFloat = 17

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(bpm.map { String(format: "%.0f", $0) } ?? "–")
                .font(Theme.dot(size)).foregroundStyle(bpm == nil ? Theme.text3 : Theme.text)
            if unsure { Text("?").font(Theme.dot(size * 0.7)).foregroundStyle(Theme.peach) }
        }
    }
}

/// Camelot key in its wheel colour.
struct KeyBadge: View {
    let camelot: String
    var unsure = false
    var large = false

    var body: some View {
        if camelot.isEmpty {
            Text("–").font(Theme.dot(large ? 22 : 13)).foregroundStyle(Theme.text3)
        } else {
            let c = Theme.camelotColor(camelot)
            HStack(spacing: 2) {
                Text(camelot).font(Theme.dot(large ? 22 : 13))
                if unsure { Text("?").font(Theme.dot(large ? 15 : 10)).opacity(0.8) }
            }
            .foregroundStyle(c)
            .padding(.horizontal, large ? 12 : 8).padding(.vertical, large ? 5 : 3)
            .background(Capsule().fill(c.opacity(0.16)).overlay(Capsule().strokeBorder(c.opacity(0.35))))
        }
    }
}

/// Five-segment energy meter.
struct EnergyMeter: View {
    let value: Double?
    var height: CGFloat = 12

    var body: some View {
        let level = value.map { Int(($0 * 5).rounded(.up)) } ?? 0
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i < level ? AnyShapeStyle(Theme.smart) : AnyShapeStyle(Theme.hairline))
                    .frame(width: 4, height: height * (0.5 + Double(i) * 0.125))
            }
        }
        .frame(height: height, alignment: .bottom)
        .opacity(value == nil ? 0.5 : 1)
    }
}

/// Album art with a tinted placeholder while loading / when none exists.
struct ArtworkView: View {
    let row: Row
    var size: CGFloat
    var radius: CGFloat = Theme.Radius.art
    @State private var image: NSImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                let tint = Theme.tint(for: row.track.album ?? row.id)
                LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note").font(.system(size: size * 0.32, weight: .medium)).foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.08)))
        .task(id: row.id) {
            image = await ArtworkLoader.shared.image(for: row.track, localPath: row.state?.localPath, deezerID: row.bpm?.deezerID)
        }
    }
}

/// Large blurred album art behind the whole window, so the UI picks up the selected track's colour.
struct AmbientBackground: View {
    let row: Row?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Theme.bg
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .blur(radius: 90).opacity(0.38).saturation(1.3)
                    .transition(.opacity)
            } else {
                RadialGradient(colors: [Theme.lilac.opacity(0.16), .clear], center: .topTrailing, startRadius: 20, endRadius: 700)
                RadialGradient(colors: [Theme.peach.opacity(0.08), .clear], center: .bottomLeading, startRadius: 20, endRadius: 600)
            }
            LinearGradient(colors: [Theme.bg.opacity(0.2), Theme.bg.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: image)
        .task(id: row?.id) {
            guard let row else { image = nil; return }
            image = await ArtworkLoader.shared.image(for: row.track, localPath: row.state?.localPath, deezerID: row.bpm?.deezerID)
        }
    }
}

/// Glass stat tile for the dashboard.
struct StatTile: View {
    let label: String
    let value: String
    var detail: String?
    var progress: Double?
    var smart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DotLabel(label)
            Text(value).font(Theme.dot(34)).foregroundStyle(Theme.text)
            if let progress {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.hairline)
                        Capsule().fill(Theme.smart).frame(width: max(4, g.size.width * progress))
                    }
                }
                .frame(height: 4)
            }
            if let detail { Text(detail).font(Theme.ui(12)).foregroundStyle(Theme.text2) }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(TileBackground(smart: smart))
    }
}

struct TileBackground: ViewModifier {
    let smart: Bool
    func body(content: Content) -> some View {
        if smart { content.smartGlass(Theme.Radius.tile) } else { content.glass(Theme.Radius.tile) }
    }
}
