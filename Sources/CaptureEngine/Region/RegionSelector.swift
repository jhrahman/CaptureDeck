import AppKit
import CoreModels

/// The real selection UI: a full-screen overlay on every display.
public struct RegionSelector: RegionSelecting {
    private let style: OverlayStyle

    public init(style: OverlayStyle = OverlayStyle()) { self.style = style }

    public func selectRegion(on snapshots: [DisplaySnapshot], kind: RegionSelectionKind) async throws -> CaptureTarget {
        try await RegionSelectionSession(snapshots: snapshots, style: style, kind: kind).run()
    }
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
    private let kind: RegionSelectionKind
    private var windows: [OverlayWindow] = []
    private var views: [RegionOverlayView] = []
    private var continuation: CheckedContinuation<CaptureTarget, any Error>?

    init(snapshots: [DisplaySnapshot], style: OverlayStyle, kind: RegionSelectionKind) {
        self.snapshots = snapshots
        self.style = style
        self.kind = kind
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

            let overlay = RegionOverlayView(frame: backdrop.bounds, snapshot: snapshot.image, style: style, kind: kind)
            overlay.autoresizingMask = [.width, .height]
            overlay.onClaim = { [weak self, weak overlay] in self?.lockOthers(except: overlay) }
            overlay.onRelease = { [weak self] in self?.unlockAll() }
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

    private func lockOthers(except active: RegionOverlayView?) {
        for view in views { view.isLocked = (view !== active) }
    }

    private func unlockAll() {
        for view in views { view.isLocked = false }
    }

    private func finish(_ result: Result<CaptureTarget, any Error>) {
        guard let continuation else { return }  // resolve once
        self.continuation = nil
        for view in views { view.onClaim = nil; view.onRelease = nil; view.onFinish = nil; view.onCancel = nil }
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
        NSApp.hide(nil)  // hand focus back to the previously active app
        continuation.resume(with: result)
    }
}
