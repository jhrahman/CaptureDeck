import AppKit
import QuartzCore

/// How the record dot in the menu bar icon blinks.
public enum BlinkStyle: String, CaseIterable, Sendable {
    /// Fades gently out and back.
    case smooth
    /// Switches cleanly between on and dim, like a camera's recording light.
    case onOff

    public var title: String { self == .smooth ? "Smooth fade" : "Classic on and off" }
}

/// The blinking record dot. Only the dot changes: the rest of the brand icon is drawn from its own artwork and stays still.
public struct RecordingBlink: Equatable, Sendable {
    public var style: BlinkStyle
    /// Seconds for one full blink.
    public var period: Double

    public init(style: BlinkStyle, period: Double) {
        self.style = style
        self.period = max(period, 0.3)
    }

    /// The dimmest the dot gets: it never disappears, so a glance at any moment still reads as "recording".
    public static let dimmest = 0.18
    /// The dot's size, and the middle of the 18 x 18 pt icon where it sits (from the brand's vector artwork).
    static let radius: CGFloat = 1.6
    static let center = CGPoint(x: 9, y: 9)
    static let red = NSColor(srgbRed: 1, green: 0x4D / 255.0, blue: 0x4F / 255.0, alpha: 1)
    /// How much of a classic blink is spent lit.
    static let litShare = 0.55

    /// The dot's strength `time` seconds after the blink began. It starts fully lit, so the icon is bright the moment
    /// recording begins.
    public func opacity(at time: Double) -> Double {
        let phase = (time / period).truncatingRemainder(dividingBy: 1)
        switch style {
        case .onOff:
            return phase < Self.litShare ? 1 : Self.dimmest
        case .smooth:
            // A wave that lingers at full and at dim, with a quick, even change between them.
            let wave = 0.5 + 0.5 * cos(2 * .pi * phase)
            let eased = wave * wave * (3 - 2 * wave)
            return Self.dimmest + (1 - Self.dimmest) * eased
        }
    }

    /// The blink as an animation that macOS runs by itself. Replacing the menu bar picture many times a second instead
    /// costs several percent of a processor core, which a recorder should not spend on its own indicator.
    public func animation() -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        switch style {
        case .onOff:
            animation.calculationMode = .discrete
            animation.values = [1.0, Self.dimmest]
            animation.keyTimes = [0, NSNumber(value: Self.litShare), 1]
        case .smooth:
            let samples = 48
            animation.values = (0...samples).map { opacity(at: period * Double($0 % samples) / Double(samples)) }
        }
        animation.duration = period
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// `base` (the brand's recording icon, 18 pt) with its dot taken out, ready for the blinking one. Drawn when shown, so
    /// it is sharp at every screen scale.
    public static func withoutDot(_ base: NSImage) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            base.draw(in: rect)
            // The dot sits inside a clear ring, so clearing a slightly larger circle touches nothing else.
            NSGraphicsContext.current?.compositingOperation = .clear
            let clear = radius + 0.45
            NSBezierPath(ovalIn: NSRect(x: center.x - clear, y: center.y - clear, width: 2 * clear, height: 2 * clear)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// The blinking dot, laid over the menu bar button's icon.
@MainActor
public final class MenuBarBlinkingDot {
    private var layer: CAShapeLayer?
    private var blink: RecordingBlink?
    private var key = ""
    private var frameObserver: NSObjectProtocol?
    private weak var button: NSButton?

    public init() {}

    public var isRunning: Bool { layer != nil }
    /// The dot's frame in the button, for tests.
    var dotFrame: CGRect? { layer?.frame }

    /// Shows the blinking icon on `button`. Calling it again with the same choices only keeps the dot in place.
    /// `key` names the artwork, which changes when the menu bar turns light or dark.
    public func show(_ blink: RecordingBlink, base: NSImage, key: String, on button: NSButton) {
        if isRunning, blink == self.blink, key == self.key, button === self.button {
            place()
            return
        }
        stop()
        (self.blink, self.key, self.button) = (blink, key, button)
        button.image = RecordingBlink.withoutDot(base)
        button.wantsLayer = true
        let dot = CAShapeLayer()
        dot.bounds = CGRect(x: 0, y: 0, width: 2 * RecordingBlink.radius, height: 2 * RecordingBlink.radius)
        dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
        dot.fillColor = RecordingBlink.red.cgColor
        dot.contentsScale = button.window?.backingScaleFactor ?? 2
        button.layer?.addSublayer(dot)
        dot.add(blink.animation(), forKey: "blink")
        layer = dot
        // The icon moves inside the button when the time appears beside it or grows an hour digit.
        button.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        place()
    }

    /// Puts the dot in the middle of the icon, wherever the button now draws it.
    public func place() {
        guard let layer, let button, let cell = button.cell as? NSButtonCell else { return }
        button.layoutSubtreeIfNeeded()
        let icon = cell.imageRect(forBounds: button.bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = CGPoint(x: icon.midX, y: icon.midY)
        CATransaction.commit()
    }

    public func stop() {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        layer?.removeFromSuperlayer()
        layer = nil
        blink = nil
        key = ""
    }
}
