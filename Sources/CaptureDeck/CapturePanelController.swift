import AppKit
import CaptureEngine
import Combine
import Settings
import SwiftUI

/// The floating capture toolbar. Everything about it (visibility, opacity, button size, which buttons)
/// comes from the Settings store and updates live.
@MainActor
final class CapturePanelController {
    private let panel: NSPanel
    private let host: NSHostingView<CapturePanelView>
    private let modes: [any CaptureMode]
    private let store: SettingsStore
    private let run: (String) -> Void
    private var suspended = false
    private var subscription: AnyCancellable?

    init(modes: [any CaptureMode], store: SettingsStore, run: @escaping (String) -> Void) {
        self.modes = modes
        self.store = store
        self.run = run
        host = NSHostingView(rootView: CapturePanelView(modes: modes, buttonSize: .medium, shortcuts: [:], run: run))

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
        reload()
        if !panel.setFrameUsingName("CaptureDeckPanel") { placeTopCenter() }

        subscription = store.changes
            .filter { $0.hasPrefix("panel.") || $0.hasPrefix("hotkey.") }
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
    }

    var isVisible: Bool { panel.isVisible }

    /// Rebuilds the buttons and applies opacity and visibility from settings.
    private func reload() {
        var shown = modes.filter { store.bool(SettingID.panelShows($0.id)) }
        if shown.isEmpty { shown = modes }                      // never leave an empty panel
        let size = PanelButtonSize(rawValue: store.string(SettingID.panelButtonSize)) ?? .medium
        var shortcuts: [String: String] = [:]
        for mode in modes { shortcuts[mode.id] = store.shortcut(SettingID.hotkey(mode.id))?.displayString }

        host.rootView = CapturePanelView(modes: shown, buttonSize: size, shortcuts: shortcuts, run: run)
        let fitting = host.fittingSize
        if panel.frame.size != fitting {
            // Keep the top-left corner where it is while the size changes.
            let top = panel.frame.maxY
            panel.setContentSize(fitting)
            panel.setFrameTopLeftPoint(CGPoint(x: panel.frame.minX, y: top))
        }
        panel.alphaValue = CGFloat(store.double(SettingID.panelOpacity))
        applyVisibility()
    }

    private func applyVisibility() {
        guard !suspended else { return }
        if store.bool(SettingID.panelVisible) { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    /// The show/hide hotkey and menu item: flips the setting, which shows or hides the panel.
    func toggle() { store.set(!store.bool(SettingID.panelVisible), for: SettingID.panelVisible) }

    func showAtLaunch() { applyVisibility() }

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
        applyVisibility()
    }

    private func placeTopCenter() {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 12))
    }
}
