import AppKit

/// Pointers shown while choosing what to capture. Each is a precise crosshair with a small badge that says which kind
/// of capture is in progress (region, fixed size, freehand, window), the way screenshot tools usually show it.
@MainActor
enum CaptureCursors {
    enum Badge: String {
        case region = "rectangle.dashed"
        case fixedSize = "aspectratio"
        case freehand = "lasso"
        case window = "macwindow"
    }

    private static var cache: [Badge: NSCursor] = [:]

    static func cursor(for badge: Badge) -> NSCursor {
        if let cached = cache[badge] { return cached }
        let cursor = make(badge)
        cache[badge] = cursor
        return cursor
    }

    private static func make(_ badge: Badge) -> NSCursor {
        let size = NSSize(width: 44, height: 44)
        let center = NSPoint(x: 15, y: 29)                       // the hot spot, in image coordinates (origin top-left)
        let image = NSImage(size: size, flipped: true) { _ in
            // Crosshair: dark outline under a white line so it reads on any background.
            func cross(_ color: NSColor, width: CGFloat) {
                color.setStroke()
                let path = NSBezierPath()
                path.lineWidth = width
                path.lineCapStyle = .round
                path.move(to: NSPoint(x: center.x - 10, y: center.y)); path.line(to: NSPoint(x: center.x + 10, y: center.y))
                path.move(to: NSPoint(x: center.x, y: center.y - 10)); path.line(to: NSPoint(x: center.x, y: center.y + 10))
                path.stroke()
            }
            cross(NSColor.black.withAlphaComponent(0.85), width: 3.4)
            cross(.white, width: 1.4)

            // Badge: a dark rounded chip with the capture kind's symbol, above and to the right of the crosshair.
            let chip = NSRect(x: 21, y: 4, width: 20, height: 20)
            NSColor.black.withAlphaComponent(0.82).setFill()
            NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6).fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let symbol = NSImage(systemSymbolName: badge.rawValue, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let inset = chip.insetBy(dx: 3, dy: 3)
                let scale = min(inset.width / symbol.size.width, inset.height / symbol.size.height)
                let drawn = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
                symbol.draw(in: NSRect(x: chip.midX - drawn.width / 2, y: chip.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
            }
            return true
        }
        return NSCursor(image: image, hotSpot: center)
    }
}
