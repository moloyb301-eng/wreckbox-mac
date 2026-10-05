import AppKit
import SwiftUI

// WreckBox logo: a pixel-art vinyl record on a 24×24 grid — black disc with groove rings, a glint,
// and a centre label in the smart gradient. One definition drives the sidebar logo and the app icon.

enum PixelRecord {
    static let grid = 32

    /// Colour of each cell, or nil for transparent.
    static func cell(_ x: Int, _ y: Int) -> Color? {
        let c = Double(grid - 1) / 2
        let dx = Double(x) - c, dy = Double(y) - c
        let r = (dx * dx + dy * dy).squareRoot()
        let angle = atan2(dy, dx) * 180 / .pi          // degrees, 0 = right, y grows downward
        switch r {
        case ..<1.6: return nil                          // spindle hole
        case ..<3.6: return Theme.lilac                  // label centre
        case ..<5.6: return Theme.peach                  // label ring
        case ..<6.3: return Color(hex: 0x050506)         // run-out groove
        case ..<14.6:
            // Two glints on opposite sides, like light catching the grooves.
            let glint = (angle > -150 && angle < -118) || (angle > 30 && angle < 62)
            let band = Int((r - 6.3) / 1.7) % 2 == 0     // alternating groove bands
            if glint { return band ? Color(hex: 0x4A4A56) : Color(hex: 0x5C5C6A) }
            return band ? Color(hex: 0x15151A) : Color(hex: 0x202027)
        case ..<15.6: return Color(hex: 0x34343E)        // rim
        default: return nil
        }
    }
}

/// The record drawn as crisp square pixels.
struct PixelRecordLogo: View {
    var size: CGFloat = 22

    var body: some View {
        Canvas { ctx, sz in
            let n = PixelRecord.grid
            let px = sz.width / CGFloat(n)
            for y in 0..<n {
                for x in 0..<n {
                    guard let color = PixelRecord.cell(x, y) else { continue }
                    // Slight overlap avoids hairline seams between pixels.
                    ctx.fill(Path(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px + 0.5, height: px + 0.5)), with: .color(color))
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// App icon artwork: the record on a dark rounded square.
struct WreckBoxIcon: View {
    var size: CGFloat = 1024

    var body: some View {
        ZStack {
            // Light grey-beige square, as in the source design's app icon, so the black record stands out.
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xF1ECE4), Color(hex: 0xDCD5CA)], startPoint: .top, endPoint: .bottom))
            PixelRecordLogo(size: size * 0.64)
                .shadow(color: .black.opacity(0.28), radius: size * 0.02, y: size * 0.012)
        }
        .frame(width: size * 0.82, height: size * 0.82)      // macOS icon grid: art inset from the canvas edge
        .shadow(color: .black.opacity(0.45), radius: size * 0.03, y: size * 0.015)
        .frame(width: size, height: size)
    }
}

/// `djlib make-icon <dir.iconset>`: renders every macOS icon size from the same drawing.
@MainActor
enum IconMaker {
    static func run(args: [String]) {
        let out = URL(fileURLWithPath: args.first ?? "WreckBox.iconset")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let r = ImageRenderer(content: WreckBoxIcon(size: CGFloat(px)))
                r.scale = 1
                guard let cg = r.cgImage else { continue }
                let rep = NSBitmapImageRep(cgImage: cg)
                let name = "icon_\(base)x\(base)" + (scale == 2 ? "@2x" : "") + ".png"
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name))
            }
        }
        print("wrote \(out.path)")
    }
}
