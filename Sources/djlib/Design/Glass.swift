import SwiftUI

// Frosted-glass surfaces: blurred material, a faint white fill, a top-lit hairline border and a
// soft shadow. `smartGlass` adds the pastel gradient used only for smart features.

struct Glass: ViewModifier {
    var radius: CGFloat
    var tint: Color?
    var shadow: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.background {
            ZStack {
                shape.fill(.ultraThinMaterial)
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
    var radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.background {
            ZStack {
                shape.fill(.ultraThinMaterial)
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
