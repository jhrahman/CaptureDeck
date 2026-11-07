import AppKit
import CaptureEngine
import SwiftUI

/// The floating capture toolbar: always on top, draggable, remembers its position, one button per capture mode.
@MainActor
final class CapturePanelController {
    private static let visibleKey = "panel.visible"
    private let panel: NSPanel
    private var suspended = false

    init(modes: [any CaptureMode], run: @escaping (String) -> Void) {
        let host = NSHostingView(rootView: CapturePanelView(modes: modes, run: run))
        host.frame.size = host.fittingSize

        panel = NSPanel(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setFrameAutosaveName("CaptureDeckPanel")
        if !panel.setFrameUsingName("CaptureDeckPanel") { placeTopCenter() }
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows the panel unless the user hid it last time.
    func showAtLaunch() {
        let hidden = UserDefaults.standard.object(forKey: Self.visibleKey) != nil && !UserDefaults.standard.bool(forKey: Self.visibleKey)
        if !hidden { panel.orderFrontRegardless() }
    }

    func toggle() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        UserDefaults.standard.set(panel.isVisible, forKey: Self.visibleKey)
    }

    /// Hide while a capture runs so the panel is never part of a screenshot.
    func suspend() async {
        guard panel.isVisible else { return }
        suspended = true
        panel.orderOut(nil)
        try? await Task.sleep(nanoseconds: 150_000_000)   // let the window server remove it
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        panel.orderFrontRegardless()
    }

    private func placeTopCenter() {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let origin = CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 12)
        panel.setFrameOrigin(origin)
    }
}
