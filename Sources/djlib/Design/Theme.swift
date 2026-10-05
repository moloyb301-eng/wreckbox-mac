import AppKit
import CoreText
import SwiftUI

// Design tokens for the DJ Library app (dark-first), after the "Notis+" Behance design:
// frosted glass over a dark base, Urbanist for UI text, the Doto dot-matrix face for labels and
// readouts, and a pastel gradient reserved for "smart" features. Kept in one place so the
// Android / iPad versions can mirror the same names and values.

enum Theme {
    // MARK: Colour
    static let bg = Color(hex: 0x08080A)
    static let bgRaised = Color(hex: 0x111115)
    static let text = Color.white.opacity(0.94)
    static let text2 = Color.white.opacity(0.60)
    static let text3 = Color.white.opacity(0.36)
    static let hairline = Color.white.opacity(0.08)
    static let glassFill = Color.white.opacity(0.045)
    static let hover = Color.white.opacity(0.06)

    static let peach = Color(hex: 0xEFAF86)
    static let lilac = Color(hex: 0xBB96DA)
    static let lightBlue = Color(hex: 0xA9C8F0)   // TODO: exact value not legible in the source design – placeholder
    /// Reserved for smart features (mix suggestions, analysis confidence, sync).
    static let smart = LinearGradient(colors: [lightBlue, peach, lilac], startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: Shape
    enum Radius {
        static let card: CGFloat = 24
        static let tile: CGFloat = 20
        static let row: CGFloat = 12
        static let art: CGFloat = 8
    }

    // MARK: Type
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Urbanist", size: size).weight(weight)
    }

    static func dot(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .custom("Doto", size: size).weight(weight)
    }

    static func registerFonts() {
        guard let dir = AppPaths.fontsDir,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension.lowercased() == "ttf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }

    // MARK: Camelot wheel colours (the hue steps around the wheel like DJ software key colours)
    static func camelotColor(_ code: String) -> Color {
        guard let n = Int(code.dropLast()) else { return text3 }
        let hue = (Double((n - 1) * 30) + 165).truncatingRemainder(dividingBy: 360) / 360
        return code.hasSuffix("B") ? Color(hue: hue, saturation: 0.55, brightness: 1.0)
                                   : Color(hue: hue, saturation: 0.45, brightness: 0.88)
    }

    /// Stable tint for a track without art.
    static func tint(for seed: String) -> Color {
        var h: UInt64 = 1469598103934665603
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Color(hue: Double(h % 360) / 360, saturation: 0.35, brightness: 0.75)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
