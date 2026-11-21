import AppKit
import SwiftUI

/// The frosted, translucent look of macOS panels. It follows light and dark mode by itself: the material, the hairlines and
/// the highlight all resolve from the effective appearance, and the desktop shows through softly behind it.
public enum Glass {
    /// A hairline for the edges of glass: a faint light line in dark mode, a faint dark one in light mode.
    public static let stroke = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.10)
    }
    /// A slightly stronger line, for the edge of a control sitting on glass.
    public static let strongStroke = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.14)
    }
    /// A soft wash that lifts a control off the glass behind it.
    public static let fill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.05)
    }
    /// The bright sheen along the top edge of glass.
    public static let sheen = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 1, alpha: 0.55)
    }
    /// A window-wide glass surface: the desktop blurs through, tinted by the light or dark appearance.
    public static let windowMaterial = NSVisualEffectView.Material.underWindowBackground
}

/// A frosted-glass background for SwiftUI views (a real `NSVisualEffectView`, so it blurs what is behind the window).
public struct GlassBackground: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blending: NSVisualEffectView.BlendingMode

    public init(material: NSVisualEffectView.Material = .headerView, blending: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blending = blending
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.material = material
        view.blendingMode = blending
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

public extension View {
    /// Frosted glass with a soft sheen on top, for bars (ribbons, toolbars, footers).
    func glassBar(material: NSVisualEffectView.Material = .headerView) -> some View {
        background(
            GlassBackground(material: material)
                .overlay(LinearGradient(colors: [Color(Glass.sheen), .clear], startPoint: .top, endPoint: .bottom).allowsHitTesting(false))
        )
    }

    /// Makes a whole window's SwiftUI content sit on window glass.
    func glassWindow() -> some View {
        background(GlassBackground(material: Glass.windowMaterial).ignoresSafeArea())
    }

    /// A one point hairline along an edge of glass.
    func glassEdge(_ edge: Alignment = .bottom) -> some View {
        overlay(alignment: edge) {
            Rectangle().fill(Color(Glass.stroke)).frame(height: 1).allowsHitTesting(false)
        }
    }
}
