import AppKit
import CoreModels

/// The real selection UI: a full-screen overlay on every display.
public struct RegionSelector: RegionSelecting {
    private let style: OverlayStyle
    private let options: @MainActor @Sendable () -> OverlayOptions

    public init(style: OverlayStyle = OverlayStyle(), options: @escaping @MainActor @Sendable () -> OverlayOptions = { OverlayOptions() }) {
        self.style = style
        self.options = options
    }

    public func selectRegion(on snapshots: [DisplaySnapshot], kind: RegionSelectionKind) async throws -> CaptureTarget {
        try await RegionSelectionSession(snapshots: snapshots, style: style, options: options, mode: .region(kind)).run()
    }

    public func pickTarget(on snapshots: [DisplaySnapshot], finder: any PickTargetFinder) async throws -> CaptureTarget {
        try await RegionSelectionSession(snapshots: snapshots, style: style, options: options, mode: .pick(finder)).run()
    }
}

private enum SessionMode {
    case region(RegionSelectionKind)
    case pick(any PickTargetFinder)
}

/// Borderless window that can take keyboard focus (needed for Esc / Return / Tab).
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Shows one overlay window per display and resolves once with the user's choice.
@MainActor
private final class RegionSelectionSession {
    private let snapshots: [DisplaySnapshot]
    private let style: OverlayStyle
    private let mode: SessionMode
    private let options: OverlayOptions
    private var windows: [OverlayWindow] = []
    private var views: [RegionOverlayView] = []
    private var continuation: CheckedContinuation<CaptureTarget, any Error>?

    init(snapshots: [DisplaySnapshot], style: OverlayStyle, options: @MainActor @Sendable () -> OverlayOptions, mode: SessionMode) {
        self.snapshots = snapshots
        self.style = style
        self.mode = mode
        self.options = options()
    }

    func run() async throws -> CaptureTarget {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            show()
        }
    }

    private func show() {
        for snapshot in snapshots {
            let window = OverlayWindow(contentRect: snapshot.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = true
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.setFrame(snapshot.frame, display: false)

            let size = snapshot.frame.size
            let backdrop = NSView(frame: CGRect(origin: .zero, size: size))
            backdrop.wantsLayer = true
            backdrop.layer?.contents = snapshot.image.cgImage
            backdrop.layer?.contentsGravity = .resize

            let overlay: RegionOverlayView
            switch mode {
            case .region(let kind):
                overlay = RegionOverlayView(frame: backdrop.bounds, snapshot: snapshot.image, style: style, options: options, kind: kind)
            case .pick(let finder):
                overlay = RegionOverlayView(frame: backdrop.bounds, snapshot: snapshot.image, style: style, options: options, finder: finder, globalOrigin: snapshot.globalBounds.origin)
                overlay.onPick = { [weak self] candidate in self?.finish(.success(Self.target(for: candidate, on: snapshot))) }
            }
            overlay.autoresizingMask = [.width, .height]
            overlay.onClaim = { [weak self, weak overlay] in self?.lockOthers(except: overlay) }
            overlay.onRelease = { [weak self] in self?.unlockAll() }
            overlay.onFinishPolygon = { [weak self] points in self?.finish(.success(.polygon(points, display: snapshot.displayID))) }
            overlay.onFinish = { [weak self] rect in self?.finish(.success(.rect(rect, display: snapshot.displayID))) }
            overlay.onCancel = { [weak self] in self?.finish(.failure(CaptureError.cancelled)) }
            backdrop.addSubview(overlay)
            window.contentView = backdrop
            window.makeFirstResponder(overlay)

            windows.append(window)
            views.append(overlay)
        }

        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        let keyIndex = snapshots.firstIndex { $0.frame.contains(mouse) } ?? 0
        for (index, window) in windows.enumerated() where index != keyIndex {
            window.orderFrontRegardless()
        }
        windows[keyIndex].makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()
    }

    /// Windows are captured as windows; elements become a rectangle in this display's points.
    private static func target(for candidate: PickCandidate, on snapshot: DisplaySnapshot) -> CaptureTarget {
        switch candidate.kind {
        case .window(let id):
            return .window(id)
        case .element:
            let local = candidate.rect
                .offsetBy(dx: -snapshot.globalBounds.minX, dy: -snapshot.globalBounds.minY)
                .intersection(CGRect(origin: .zero, size: snapshot.globalBounds.size))
            return .rect(local.isNull ? .zero : local, display: snapshot.displayID)
        }
    }

    private func lockOthers(except active: RegionOverlayView?) {
        for view in views { view.isLocked = (view !== active) }
    }

    private func unlockAll() {
        for view in views { view.isLocked = false }
    }

    private func finish(_ result: Result<CaptureTarget, any Error>) {
        guard let continuation else { return }  // resolve once
        self.continuation = nil
        for view in views { view.onClaim = nil; view.onRelease = nil; view.onFinish = nil; view.onCancel = nil; view.onPick = nil; view.onFinishPolygon = nil }
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
        NSApp.hide(nil)  // hand focus back to the previously active app
        continuation.resume(with: result)
    }
}
