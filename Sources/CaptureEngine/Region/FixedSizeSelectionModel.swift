import CoreGraphics
import Foundation

/// A rectangle of a fixed size in *pixels* that follows the mouse, kept inside one display.
/// Coordinates are display points, origin top-left. Output is snapped to whole pixels,
/// so a requested 801 px width is captured as exactly 801 px.
struct FixedSizeSelectionModel {
    let bounds: CGRect
    let scale: CGFloat
    private(set) var sizePx: CGSize
    private var center: CGPoint?

    init(bounds: CGRect, scale: CGFloat, sizePx: CGSize) {
        self.bounds = bounds
        self.scale = max(scale, 1)
        self.sizePx = CGSize(width: max(1, sizePx.width.rounded()), height: max(1, sizePx.height.rounded()))
    }

    /// Size in points, never larger than the display.
    private var sizePt: CGSize {
        CGSize(width: min(sizePx.width / scale, bounds.width), height: min(sizePx.height / scale, bounds.height))
    }

    var selection: CGRect? {
        guard let center else { return nil }
        let size = sizePt
        var x = center.x - size.width / 2
        var y = center.y - size.height / 2
        x = min(max(x, bounds.minX), bounds.maxX - size.width)
        y = min(max(y, bounds.minY), bounds.maxY - size.height)
        // Snap origin to the pixel grid.
        return CGRect(x: (x * scale).rounded() / scale, y: (y * scale).rounded() / scale,
                      width: size.width, height: size.height)
    }

    mutating func move(to point: CGPoint) { center = point }

    mutating func nudge(dx: CGFloat, dy: CGFloat) {
        guard let c = center else { return }
        center = CGPoint(x: c.x + dx, y: c.y + dy)
    }

    /// Change the size by whole pixels (Shift + arrows).
    mutating func resize(dxPx: CGFloat, dyPx: CGFloat) {
        sizePx = CGSize(width: max(1, sizePx.width + dxPx), height: max(1, sizePx.height + dyPx))
    }

    mutating func setSize(px: CGSize) {
        sizePx = CGSize(width: max(1, px.width.rounded()), height: max(1, px.height.rounded()))
    }
}

/// Remembers the last fixed size between captures ("800x600").
public enum FixedSizePreference {
    static let key = "capture.fixedSizePx"

    static func parse(_ text: String) -> CGSize? {
        let parts = text.split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w >= 1, h >= 1 else { return nil }
        return CGSize(width: w, height: h)
    }

    static func format(_ size: CGSize) -> String { "\(Int(size.width))x\(Int(size.height))" }

    public static func load(default fallback: CGSize, defaults: UserDefaults = .standard) -> CGSize {
        defaults.string(forKey: key).flatMap(parse) ?? fallback
    }

    public static func save(_ size: CGSize, defaults: UserDefaults = .standard) {
        defaults.set(format(size), forKey: key)
    }
}
