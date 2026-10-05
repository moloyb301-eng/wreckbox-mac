import SwiftUI

// Frosted-glass surfaces: blurred material, a faint white fill, a top-lit hairline border and a
// soft shadow. `smartGlass` adds the pastel gradient used only for smart features.

struct Glass: ViewModifier {
    @Environment(\.snapshotMode) private var snapshot
    var radius: CGFloat
    var tint: Color?
    var shadow: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.background {
            ZStack {
                if !snapshot { shape.fill(.ultraThinMaterial) }
                shape.fill(Theme.glassFill)
                if let tint { shape.fill(tint.opacity(0.10)) }
            }
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.03)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(shadow ? 0.35 : 0), radius: 18, y: 8)
        }
    }
}

struct SmartGlass: ViewModifier {
    @Environment(\.snapshotMode) private var snapshot
    var radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.background {
            ZStack {
                if !snapshot { shape.fill(.ultraThinMaterial) }
                shape.fill(Theme.smart).opacity(0.16)
            }
            .overlay(shape.strokeBorder(Theme.smart.opacity(0.55), lineWidth: 1))
            .shadow(color: Theme.lilac.opacity(0.18), radius: 22, y: 8)
        }
    }
}

extension View {
    func glass(_ radius: CGFloat = Theme.Radius.card, tint: Color? = nil, shadow: Bool = true) -> some View {
        modifier(Glass(radius: radius, tint: tint, shadow: shadow))
    }

    func smartGlass(_ radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(SmartGlass(radius: radius))
    }
}

// MARK: - Snapshot support

private struct SnapshotModeKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True when rendering off-screen (`djlib snapshot`): scroll views become plain stacks, materials are skipped.
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

/// ScrollView that renders as a plain stack in snapshot mode (ImageRenderer can't draw scroll views).
struct Scroller<Content: View>: View {
    @Environment(\.snapshotMode) private var snapshot
    var axis: Axis.Set = .vertical
    var indicators = true
    @ViewBuilder var content: Content

    var body: some View {
        if snapshot {
            if axis == .horizontal { HStack(spacing: 0) { content }.frame(width: 0, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading).clipped() }
            else { VStack(spacing: 0) { content }.fixedSize(horizontal: false, vertical: true).frame(height: 0, alignment: .top).frame(maxHeight: .infinity, alignment: .top).clipped() }
        } else {
            ScrollView(axis, showsIndicators: indicators) { content }
        }
    }
}
