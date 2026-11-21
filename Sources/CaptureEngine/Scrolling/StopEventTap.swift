import AppKit
import CoreGraphics

/// Watches the mouse and keyboard while a scrolling capture runs, and *consumes* the events that mean "stop", so a stop click
/// never reaches the page underneath (it could press a link or play a video). Needs the Accessibility permission, which
/// scrolling capture needs anyway. If macOS refuses to create it, `make` returns nil and the caller falls back to
/// listening only (clicks then also reach the page).
final class StopEventTap: @unchecked Sendable {
    /// Marks events CaptureDeck posts itself, so they are never mistaken for the user's.
    static let syntheticMarker: Int64 = 0x43445343

    enum Action { case finish, cancel }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let region: CGRect                     // global display coordinates, origin top-left
    private let ignored: @Sendable () -> [CGRect]  // e.g. our own status panel, whose buttons must keep working
    private let buttonAction: @Sendable (CGPoint) -> Action?
    private let onAction: @Sendable (Action) -> Void
    private var swallowMouseUp = false

    private init(region: CGRect, ignored: @escaping @Sendable () -> [CGRect], buttonAction: @escaping @Sendable (CGPoint) -> Action?,
                 onAction: @escaping @Sendable (Action) -> Void) {
        self.region = region
        self.ignored = ignored
        self.buttonAction = buttonAction
        self.onAction = onAction
    }

    static func make(region: CGRect, ignored: @escaping @Sendable () -> [CGRect], buttonAction: @escaping @Sendable (CGPoint) -> Action? = { _ in nil },
                     onAction: @escaping @Sendable (Action) -> Void) -> StopEventTap? {
        let tapObject = StopEventTap(region: region, ignored: ignored, buttonAction: buttonAction, onAction: onAction)
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<StopEventTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(tapObject).toOpaque()) else { return nil }
        tapObject.tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        tapObject.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return tapObject
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// Whether a click here counts as "stop": inside the captured window, and not on our own panel.
    func accepts(_ point: CGPoint) -> Bool {
        region.contains(point) && !ignored().contains { $0.contains(point) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }       // macOS switches slow taps off; switch it back on
            return Unmanaged.passUnretained(event)
        default: break
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return Unmanaged.passUnretained(event) }
        switch type {
        case .leftMouseDown:
            // The panel's own Cancel / Done buttons: act on the press itself, so they work whatever else is going on.
            if let action = buttonAction(event.location) {
                swallowMouseUp = true
                onAction(action)
                return nil
            }
            guard accepts(event.location) else { return Unmanaged.passUnretained(event) }
            swallowMouseUp = true
            onAction(.finish)
            return nil
        case .leftMouseUp:
            if swallowMouseUp { swallowMouseUp = false; return nil }
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == 53 { if type == .keyDown { onAction(.cancel) }; return nil }                    // Esc
            if code == 36 || code == 76 { if type == .keyDown { onAction(.finish) }; return nil }      // Return / Enter
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
