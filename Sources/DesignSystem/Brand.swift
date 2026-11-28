import AppKit
import SwiftUI

/// The CaptureDeck brand: its colours, and the surfaces of windows that carry it.
public enum Brand {
    /// The colours of the logo. They are the same in light and dark mode.
    public static let navy = NSColor(hex: 0x14213D)
    public static let recordRed = NSColor(hex: 0xFF4D4F)

    /// Behind a page of cards: a faint navy cast in both modes. Slightly see-through, so the window's glass shows.
    public static let page = adaptive(dark: NSColor(hex: 0x0E1526).withAlphaComponent(0.86), light: NSColor(hex: 0xF2F3F7).withAlphaComponent(0.86))
    public static let card = adaptive(dark: NSColor(hex: 0x182238), light: .white)
    public static let cardBorder = adaptive(dark: NSColor(white: 1, alpha: 0.09), light: NSColor(hex: 0x14213D).withAlphaComponent(0.10))
    public static let divider = adaptive(dark: NSColor(white: 1, alpha: 0.07), light: NSColor(hex: 0x14213D).withAlphaComponent(0.08))
    public static let bar = adaptive(dark: NSColor(hex: 0x131C30), light: NSColor(hex: 0xFBFBFD))

    private static func adaptive(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
}

/// The logo, drawn from the shapes of the brand's vector artwork, so it is sharp at any size and keeps its colours (macOS
/// may restyle the app icon itself to match the system's icon style).
public struct BrandMark: View {
    private let showsViewfinder: Bool
    private let showsBackground: Bool

    /// The brand leaves out the viewfinder corners below 64 pt, where they would turn to mush.
    public init(showsViewfinder: Bool = false, showsBackground: Bool = true) {
        (self.showsViewfinder, self.showsBackground) = (showsViewfinder, showsBackground)
    }

    public var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 512
            context.scaleBy(x: scale, y: scale)
            if showsBackground {
                context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: 512, height: 512), cornerRadius: 116), with: .color(Color(Brand.navy)))
            }
            if showsViewfinder {
                context.stroke(Self.viewfinder, with: .color(.white), style: StrokeStyle(lineWidth: 22, lineCap: .round))
                context.translateBy(x: 256, y: 256)
                context.scaleBy(x: 0.84, y: 0.84)
                context.translateBy(x: -256, y: -256)
            }
            context.stroke(Self.letterC, with: .color(.white), style: StrokeStyle(lineWidth: 54, lineCap: .round))
            context.fill(Self.letterD, with: .color(.white))
            context.fill(Self.circle(42), with: .color(Color(Brand.navy)))
            context.fill(Self.circle(23), with: .color(Color(Brand.recordRed)))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("CaptureDeck logo")
    }

    private static func circle(_ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: 256 - radius, y: 256 - radius, width: 2 * radius, height: 2 * radius))
    }

    /// An arc of radius 150 about the middle, open to the right between the two 45 degree points.
    private static let letterC = Path { path in
        path.addArc(center: CGPoint(x: 256, y: 256), radius: 150, startAngle: .degrees(-45), endAngle: .degrees(45), clockwise: true)
    }

    private static let letterD = Path { path in
        path.move(to: CGPoint(x: 198, y: 178))
        path.addLine(to: CGPoint(x: 252, y: 178))
        path.addArc(center: CGPoint(x: 252, y: 256), radius: 78, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: 198, y: 334))
        path.closeSubpath()
    }

    private static let viewfinder = Path { path in
        func corner(_ a: CGPoint, _ b: CGPoint, _ turn: CGPoint, _ c: CGPoint, _ d: CGPoint) {
            path.move(to: a)
            path.addLine(to: b)
            path.addQuadCurve(to: c, control: turn)
            path.addLine(to: d)
        }
        corner(CGPoint(x: 62, y: 130), CGPoint(x: 62, y: 98), CGPoint(x: 62, y: 62), CGPoint(x: 98, y: 62), CGPoint(x: 130, y: 62))
        corner(CGPoint(x: 382, y: 62), CGPoint(x: 414, y: 62), CGPoint(x: 450, y: 62), CGPoint(x: 450, y: 98), CGPoint(x: 450, y: 130))
        corner(CGPoint(x: 450, y: 382), CGPoint(x: 450, y: 414), CGPoint(x: 450, y: 450), CGPoint(x: 414, y: 450), CGPoint(x: 382, y: 450))
        corner(CGPoint(x: 130, y: 450), CGPoint(x: 98, y: 450), CGPoint(x: 62, y: 450), CGPoint(x: 62, y: 414), CGPoint(x: 62, y: 382))
    }
}
