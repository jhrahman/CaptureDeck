import AppKit
import CaptureEngine
import DesignSystem
import OSLog
import Platform

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "app.capturedeck.CaptureDeck", category: "app")
    private let appearance = AppearanceController()
    private let hotkeys = HotkeyManager()
    // Composition root: register capture modes here. Menu items and hotkeys are generated from this list.
    private let coordinator: CaptureCoordinator = {
        let overlay = RegionSelector(style: OverlayStyle(accent: Theme.accent))
        let lastCapture = LastCaptureStore()
        return CaptureCoordinator(modes: [
            FullScreenCaptureMode(),
            RegionCaptureMode(selector: overlay),
            ActiveWindowCaptureMode(),
            WindowObjectCaptureMode(selector: overlay),
            FreehandCaptureMode(selector: overlay),
            FixedSizeCaptureMode(selector: overlay),
            RepeatLastCaptureMode(store: lastCapture),
        ], lastCapture: lastCapture)
    }()
    private var statusItem: StatusItemController?
    private var panel: CapturePanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appearance.apply()
        let panel = CapturePanelController(modes: coordinator.modes) { [coordinator] id in coordinator.run(modeID: id) }
        self.panel = panel
        coordinator.beforeCapture = { await panel.suspend() }
        coordinator.afterCapture = { panel.resume() }
        statusItem = StatusItemController(appearance: appearance, coordinator: coordinator, panel: panel)
        registerHotkeys()
        panel.showAtLaunch()
    }

    private func registerHotkeys() {
        do {
            try hotkeys.register(name: "togglePanel", shortcut: StatusItemController.togglePanelShortcut) { [weak self] in
                self?.panel?.toggle()
            }
        } catch {
            log.error("Could not register the show/hide panel hotkey: \(String(describing: error), privacy: .public)")
        }
        for mode in coordinator.modes {
            guard let shortcut = mode.defaultShortcut else { continue }
            do {
                try hotkeys.register(name: mode.id, shortcut: shortcut) { [coordinator] in
                    coordinator.run(modeID: mode.id)
                }
            } catch {
                // A conflict UI arrives with the Settings window; for now just record it.
                log.error("Could not register hotkey for \(mode.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }
}
