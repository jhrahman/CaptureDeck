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
    private let coordinator = CaptureCoordinator(modes: [
        FullScreenCaptureMode(),
        RegionCaptureMode(selector: RegionSelector(style: OverlayStyle(accent: Theme.accent))),
        ActiveWindowCaptureMode(),
        FixedSizeCaptureMode(selector: RegionSelector(style: OverlayStyle(accent: Theme.accent))),
    ])
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appearance.apply()
        statusItem = StatusItemController(appearance: appearance, coordinator: coordinator)
        registerHotkeys()
    }

    private func registerHotkeys() {
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
