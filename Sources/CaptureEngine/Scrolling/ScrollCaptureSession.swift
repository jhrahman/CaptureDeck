import AppKit
import SwiftUI

/// What the user sees and does while a scrolling capture runs: a red frame around the window, a small floating
/// status panel (frames, size, Done / Cancel), and the ways to stop: click the window, Return, or Done. Esc cancels.
@MainActor
final class ScrollCaptureSession {
    enum Reason { case done, cancelled }

    /// Where the panel's two buttons are, in the panel's own coordinates (origin top-left), reported by the panel's view.
    final class ButtonFrames: @unchecked Sendable {
        var done = CGRect.zero
        var cancel = CGRect.zero
    }

    final class Model: ObservableObject {
        @Published var status = "Starting…"
        @Published var frames = 0
        @Published var length = 0
        @Published var axis = ""
        @Published var manual = false
    }

    private(set) var reason: Reason?
    let model = Model()
    private let buttonFrames = ButtonFrames()
    private let windowFrame: NSRect              // Cocoa coordinates
    private let globalBounds: CGRect             // global display coordinates, origin top-left
    private var tap: StopEventTap?
    private var observer: NSObjectProtocol?
    /// Posted when the user presses the scrolling-capture shortcut again, which also means "finish".
    static let stopRequested = Notification.Name.scrollingCaptureStopRequested
    private var frameWindow: NSWindow?
    private var panel: NSPanel?
    private var monitors: [Any] = []
    var armed = false                      // internal for tests

    /// `bounds`: the window's frame in global display coordinates (origin top-left).
    private let usesEventTap: Bool

    init(bounds: CGRect, usesEventTap: Bool = true) {
        self.usesEventTap = usesEventTap
        let primaryHeight = NSScreen.screens.first?.frame.height ?? bounds.maxY
        globalBounds = bounds
        windowFrame = NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    func start() {
        showFrame()
        showPanel()
        // The click that started the capture is already consumed; wait a moment so it cannot also end it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.armed = true }
        installStopWatchers()
    }

    /// The reliable way to stop: an event tap that also swallows the stop click. If macOS will not give us one, fall back to
    /// listening for clicks and keys (the click then also reaches the page).
    private func installStopWatchers() {
        observer = NotificationCenter.default.addObserver(forName: Self.stopRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        let panelRect = panelGlobalRect()
        let frames = buttonFrames
        let buttonAction: @Sendable (CGPoint) -> StopEventTap.Action? = { point in
            HUDHitTesting.action(at: point, panel: panelRect, done: frames.done, cancel: frames.cancel)
        }
        let action: @Sendable (StopEventTap.Action) -> Void = { [weak self] action in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, self.armed else { return }
                ScrollDebugDump().log("stop request from the event tap: \(action)  (panel buttons: done \(self.buttonFrames.done.integral), cancel \(self.buttonFrames.cancel.integral))")
                if action == .finish { self.finish() } else { self.cancel() }
            } }
        }
        tap = usesEventTap ? StopEventTap.make(region: globalBounds, ignored: { [panelRect] in [panelRect] }, buttonAction: buttonAction, onAction: action) : nil
        ScrollDebugDump().log("stop watchers: \(tap == nil ? "listening only (no event tap)" : "event tap")")
        guard tap == nil else { return }
        // Built as a plain @Sendable closure: it runs on whatever thread AppKit delivers the event on. Only values that are
        // valid for the event's type are read (a mouse event has no key code, and asking for it is a fatal error).
        let handler: @Sendable (NSEvent) -> Void = { [weak self] event in
            let type = event.type
            let keyCode: UInt16 = type == .keyDown ? event.keyCode : 0
            let location = NSEvent.mouseLocation
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(type, keyCode: keyCode, location: location) } }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .keyDown], handler: handler) { monitors.append(global) }
    }

    private func panelGlobalRect() -> CGRect {
        guard let panel else { return .zero }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: panel.frame.minX, y: primaryHeight - panel.frame.maxY, width: panel.frame.width, height: panel.frame.height)
    }

    func handle(_ type: NSEvent.EventType, keyCode: UInt16, location: NSPoint) {
        ScrollDebugDump().log("event \(type.rawValue) key=\(keyCode) at \(Int(location.x)),\(Int(location.y)) windowFrame=\(windowFrame) armed=\(armed) reason=\(String(describing: reason))")
        guard armed, reason == nil else { return }
        switch type {
        case .leftMouseDown where windowFrame.contains(location): finish()
        case .keyDown where keyCode == 53: cancel()
        case .keyDown where keyCode == 36 || keyCode == 76: finish()
        default: break
        }
    }

    /// A short message in the status panel (why a capture ended).
    func setNotice(_ text: String) {
        model.manual = false
        model.status = text
    }

    func setManual() {
        model.manual = true
        model.status = "Scroll the page yourself"
    }

    func finish() { if reason == nil { reason = .done; model.status = "Finishing…" } }
    func cancel() { if reason == nil { reason = .cancelled } }

    func update(frames: Int, length: Int, axis: ScrollStitcher.Axis) {
        model.status = "Scrolling…"
        model.frames = frames
        model.length = length
        model.axis = axis == .vertical ? "tall" : "wide"
    }

    func stop() {
        tap?.stop()
        tap = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        for window in [frameWindow, panel] { window?.orderOut(nil) }
        frameWindow = nil
        panel = nil
    }

    // MARK: Windows

    private func overlayWindow(_ frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return window
    }

    private func showFrame() {
        let window = overlayWindow(windowFrame)
        window.ignoresMouseEvents = true                      // clicks and scroll go straight to the window below
        window.contentView = RedFrameView(frame: NSRect(origin: .zero, size: windowFrame.size))
        window.orderFrontRegardless()
        frameWindow = window
    }

    private func showPanel() {
        let size = NSSize(width: 380, height: 64)
        let screen = NSScreen.screens.first { $0.frame.intersects(windowFrame) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? windowFrame
        let origin = NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 14)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .screenSaver              // after isFloatingPanel, which would otherwise reset it to a lower level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: PanelView(model: model, frames: buttonFrames, onDone: { [weak self] in self?.finish() },
                                                             onCancel: { [weak self] in self?.cancel() }))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private final class RedFrameView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            path.lineWidth = 4
            NSColor(srgbRed: 1, green: 0.19, blue: 0.19, alpha: 1).setStroke()
            path.stroke()
        }
    }

    private struct PanelView: View {
        @ObservedObject var model: Model
        let frames: ButtonFrames
        let onDone: () -> Void
        let onCancel: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.frames > 0 ? "\(model.status)  \(model.frames) screens · \(model.length.formatted()) px \(model.axis)" : model.status)
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    Text(model.manual ? "CaptureDeck is following your scrolling · click the window or press Return when done" : "Click the window, press Return or the shortcut again to finish · Esc cancels")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("Cancel", action: onCancel).buttonStyle(HUDButtonStyle(prominent: false))
                    .background(GeometryReader { proxy in Color.clear.onAppear { frames.cancel = proxy.frame(in: .named("hud")) }
                        .onChange(of: proxy.frame(in: .named("hud"))) { frames.cancel = $0 } })
                Button("Done", action: onDone).buttonStyle(HUDButtonStyle(prominent: true))
                    .background(GeometryReader { proxy in Color.clear.onAppear { frames.done = proxy.frame(in: .named("hud")) }
                        .onChange(of: proxy.frame(in: .named("hud"))) { frames.done = $0 } })
            }
            .padding(.horizontal, 14)
            .frame(width: 380, height: 64)
            .coordinateSpace(name: "hud")           // the whole panel: button frames are measured from its top-left corner
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        }
    }
}

/// The panel's buttons. The panel never becomes the active window, where standard buttons look flat (and macOS gives them no
/// hover state at all), so they draw their own: they light up and lift under the pointer, and sink when pressed.
private struct HUDButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        Look(label: configuration.label, prominent: prominent, pressed: configuration.isPressed)
    }

    private struct Look: View {
        let label: ButtonStyleConfiguration.Label
        let prominent: Bool
        let pressed: Bool
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            label
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(prominent || hovering ? Color.white : Color.primary)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(Color.white.opacity(hovering ? 0.45 : 0.12)))
                .brightness(pressed ? -0.15 : (hovering && prominent ? 0.1 : 0))
                .shadow(color: (prominent ? Color.accentColor : Color.red).opacity(hovering ? 0.55 : 0), radius: 5)
                .scaleEffect(pressed ? 0.96 : (hovering ? 1.06 : 1))
                .animation(.easeOut(duration: 0.12), value: hovering)
                .background(HoverSensor { hovering = $0 })
        }

        private var fill: Color {
            if prominent { return .accentColor }
            return hovering ? Color(red: 0.86, green: 0.24, blue: 0.22) : Color.primary.opacity(0.12)      // red: it throws the capture away
        }
    }
}

/// Reports the pointer entering and leaving, also while another app is the active one (it is, during a scrolling capture).
private struct HoverSensor: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> SensorView { SensorView() }
    func updateNSView(_ view: SensorView, context: Context) { view.onChange = onChange }

    final class SensorView: NSView {
        var onChange: (Bool) -> Void = { _ in }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }
    }
}

public extension Notification.Name {
    /// Post this while a scrolling capture runs to finish it (the coordinator does when the shortcut is pressed again).
    static let scrollingCaptureStopRequested = Notification.Name("CaptureDeck.stopScrollingCapture")
}


/// Which panel button (if any) a point in global display coordinates lands on. Used by the event tap so the buttons work on
/// the press itself, regardless of whether the panel is the active window.
enum HUDHitTesting {
    static func action(at point: CGPoint, panel: CGRect, done: CGRect, cancel: CGRect, slop: CGFloat = 4) -> StopEventTap.Action? {
        guard panel.contains(point) else { return nil }
        let local = CGPoint(x: point.x - panel.minX, y: point.y - panel.minY)
        if !done.isEmpty, done.insetBy(dx: -slop, dy: -slop).contains(local) { return .finish }
        if !cancel.isEmpty, cancel.insetBy(dx: -slop, dy: -slop).contains(local) { return .cancel }
        return nil
    }
}
