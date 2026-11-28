import AppKit
import Carbon.HIToolbox

/// Which key presses are shown in a recording.
public enum KeystrokeMode: String, CaseIterable, Sendable {
    case off, shortcuts, all

    public var title: String {
        switch self {
        case .off: "Off"
        case .shortcuts: "Shortcuts and special keys only"
        case .all: "Every key, including typed text"
        }
    }
}

public enum KeystrokeText {
    private static let special: [UInt16: String] = [
        36: "↩", 76: "⌅", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 53: "esc", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
    /// Special keys that are also ordinary typing: not shown on their own in "shortcuts" mode.
    private static let typingKeys: Set<UInt16> = [49, 51]

    /// What to show for a key press, or nil to show nothing. In "shortcuts" mode ordinary typing is never shown, so text
    /// and passwords stay out of the video.
    public static func describe(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags, mode: KeystrokeMode) -> String? {
        guard mode != .off else { return nil }
        let commandLike = !modifiers.intersection([.command, .control, .option]).isEmpty
        let isSpecial = special[keyCode] != nil && !typingKeys.contains(keyCode)
        if mode == .shortcuts, !commandLike, !isSpecial { return nil }
        guard let key = special[keyCode] ?? characters.map({ commandLike ? $0.uppercased() : $0 }), !key.isEmpty,
              key.unicodeScalars.allSatisfy({ $0.value >= 32 && !(0xF700...0xF8FF).contains($0.value) }) else { return nil }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift), commandLike || special[keyCode] != nil { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key
    }
}

/// The look of the soft circle that follows the pointer.
public enum HaloStyle: String, CaseIterable, Sendable {
    case filled, ring, both
    public var title: String {
        switch self {
        case .filled: "Soft filled circle"
        case .ring: "Ring only"
        case .both: "Filled circle with a ring"
        }
    }
}

public struct PointerHalo: Equatable, Sendable {
    public var color: NSColor
    /// In screen points.
    public var diameter: CGFloat
    public var style: HaloStyle
    public init(color: NSColor, diameter: CGFloat, style: HaloStyle) { (self.color, self.diameter, self.style) = (color, diameter, style) }
}

public struct ClickEffect: Equatable, Sendable {
    public var leftColor: NSColor
    public var rightColor: NSColor
    public var diameter: CGFloat
    public init(leftColor: NSColor, rightColor: NSColor, diameter: CGFloat) { (self.leftColor, self.rightColor, self.diameter) = (leftColor, rightColor, diameter) }
}

public struct HighlightOptions: Equatable, Sendable {
    public var halo: PointerHalo?
    public var clicks: ClickEffect?
    public var keystrokes: KeystrokeMode
    public init(halo: PointerHalo? = nil, clicks: ClickEffect? = nil, keystrokes: KeystrokeMode = .off) {
        (self.halo, self.clicks, self.keystrokes) = (halo, clicks, keystrokes)
    }
    public var isEmpty: Bool { halo == nil && clicks == nil && keystrokes == .off }
}

/// A see-through, click-through window over the recorded screen that draws a circle around the pointer, a ripple where the
/// mouse is clicked and a label for pressed keys. What it draws is part of the recording.
@MainActor
public final class InputHighlightOverlay {
    private let window: NSWindow
    private(set) var options: HighlightOptions
    private let area: () -> NSRect                       // the recorded rectangle now, in Cocoa screen coordinates
    private let ignored: () -> NSRect                    // our own controls
    private var monitors: [Any] = []
    private var running = false
    private var haloLayer: CAShapeLayer?
    private var follower: Timer?
    private var keyLabel: CATextLayer?
    private var keyBackground: CALayer?
    private var hideKeys: DispatchWorkItem?

    public init(screen: NSScreen, options: HighlightOptions, area: @escaping () -> NSRect, ignoring ignored: @escaping () -> NSRect) {
        self.options = options
        self.area = area
        self.ignored = ignored
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()
    }

    public var windowID: CGWindowID { CGWindowID(max(window.windowNumber, 0)) }
    var haloFrame: CGRect? { haloLayer.map { $0.isHidden ? .null : $0.frame } }

    public func start() {
        running = true
        install()
    }

    /// New choices from Settings, applied while recording.
    public func update(_ new: HighlightOptions) {
        guard new != options else { return }
        options = new
        if running { install() }
    }

    public func stop() {
        running = false
        remove()
        window.orderOut(nil)
    }

    private func remove() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        follower?.invalidate()
        follower = nil
        haloLayer?.removeFromSuperlayer()
        haloLayer = nil
        keyBackground?.removeFromSuperlayer()
        keyBackground = nil
        keyLabel = nil
    }

    /// Watching keys in other apps needs the Accessibility permission; the pointer and clicks need none.
    private func install() {
        remove()
        if let halo = options.halo { installHalo(halo) }
        var mask: NSEvent.EventTypeMask = []
        if options.clicks != nil { mask.formUnion([.leftMouseDown, .rightMouseDown, .otherMouseDown]) }
        if options.keystrokes != .off { mask.insert(.keyDown) }
        guard !mask.isEmpty else { return }
        let handler: @Sendable (NSEvent) -> Void = { [weak self] event in
            let type = event.type
            let isKey = type == .keyDown
            let keyCode = isKey ? event.keyCode : 0
            let characters = isKey ? event.charactersIgnoringModifiers : nil
            let flags = event.modifierFlags
            let location = NSEvent.mouseLocation
            DispatchQueue.main.async { MainActor.assumeIsolated {
                if isKey { self?.key(keyCode, characters: characters, flags: flags) } else { self?.click(at: location, right: type == .rightMouseDown) }
            } }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in handler(event); return event }) { monitors.append(local) }
    }

    private func installHalo(_ halo: PointerHalo) {
        guard let root = window.contentView?.layer else { return }
        let layer = CAShapeLayer()
        let bounds = CGRect(x: 0, y: 0, width: halo.diameter, height: halo.diameter)
        layer.bounds = bounds
        layer.path = CGPath(ellipseIn: bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        // The chosen colour's own transparency sets how strong the filled circle is; the ring is drawn solid.
        layer.fillColor = halo.style == .ring ? nil : halo.color.cgColor
        layer.strokeColor = halo.style == .filled ? nil : halo.color.withAlphaComponent(1).cgColor
        layer.lineWidth = 2.5
        root.addSublayer(layer)
        haloLayer = layer
        moveHalo()
        // Follows the pointer at the fastest rate a screen shows, also while another app is busy with the mouse.
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.moveHalo() } }
        RunLoop.main.add(timer, forMode: .common)
        follower = timer
    }

    func moveHalo(to point: NSPoint = NSEvent.mouseLocation) {
        guard let haloLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)                                 // no animation: it must sit exactly on the pointer
        haloLayer.position = local(point)
        haloLayer.isHidden = !window.frame.contains(point) || ignored().contains(point)
        CATransaction.commit()
    }

    private func local(_ point: NSPoint) -> CGPoint { CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY) }

    private func click(at point: NSPoint, right: Bool) {
        guard let effect = options.clicks, let layer = window.contentView?.layer, !ignored().contains(point) else { return }
        let ring = CAShapeLayer()
        let radius = effect.diameter / 2
        ring.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: effect.diameter, height: effect.diameter), transform: nil)
        ring.position = local(point)
        let color = right ? effect.rightColor : effect.leftColor
        ring.fillColor = color.withAlphaComponent(0.3 * color.alphaComponent).cgColor
        ring.strokeColor = color.cgColor
        ring.lineWidth = 3
        ring.opacity = 0
        layer.addSublayer(ring)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.35
        grow.toValue = 1.15
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.55, 1]
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "click")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { ring.removeFromSuperlayer() }
    }

    private func key(_ keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags) {
        // Never show anything while a password field has the keyboard.
        guard !IsSecureEventInputEnabled(),
              let text = KeystrokeText.describe(keyCode: keyCode, characters: characters, modifiers: flags, mode: options.keystrokes),
              let root = window.contentView?.layer else { return }
        if keyLabel == nil {
            let background = CALayer(), label = CATextLayer()
            background.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
            background.cornerRadius = 12
            label.alignmentMode = .center
            label.contentsScale = window.backingScaleFactor
            background.addSublayer(label)
            root.addSublayer(background)
            (keyBackground, keyLabel) = (background, label)
        }
        let font = NSFont.systemFont(ofSize: 26, weight: .semibold)
        let width = max((text as NSString).size(withAttributes: [.font: font]).width + 40, 70)
        let recorded = area()
        let origin = local(NSPoint(x: recorded.midX - width / 2, y: recorded.minY + 40))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        keyBackground?.frame = CGRect(x: origin.x, y: origin.y, width: width, height: 52)
        keyBackground?.opacity = 1
        keyLabel?.frame = CGRect(x: 0, y: 8, width: width, height: 34)
        keyLabel?.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        CATransaction.commit()
        hideKeys?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.keyBackground?.opacity = 0 }
        hideKeys = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }
}

/// A thin red frame just outside the recorded region, so the user can see what is in the video. Left out of the recording.
@MainActor
public final class RegionOutline {
    private let window: NSWindow

    public init(around area: NSRect) {
        let frame = area.insetBy(dx: -3, dy: -3)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = Outline(frame: NSRect(origin: .zero, size: frame.size))
        window.orderFrontRegardless()
    }

    public var windowID: CGWindowID { CGWindowID(max(window.windowNumber, 0)) }
    public func close() { window.orderOut(nil) }

    private final class Outline: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            NSColor.systemRed.setStroke()
            path.stroke()
        }
    }
}
