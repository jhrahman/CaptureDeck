import CaptureEngine
import CoreModels
import Combine
import OSLog
import Platform
import Settings

/// Keeps the global hotkeys in step with the Settings store: registers them at launch and
/// re-registers whenever one is changed (no restart needed). Problems show as a note in Settings.
@MainActor
final class HotkeyBindings {
    private let log = Logger(subsystem: "app.capturedeck.CaptureDeck", category: "hotkeys")
    private let store: SettingsStore
    private let manager: HotkeyManager
    private var actions: [String: @MainActor () -> Void] = [:]
    private var subscription: AnyCancellable?
    private var recordingObserver: Any?
    private var paused = false

    init(store: SettingsStore, manager: HotkeyManager = HotkeyManager()) {
        self.store = store
        self.manager = manager
    }

    /// `settingID` is the hotkey setting (e.g. "hotkey.region"); `action` runs when it is pressed.
    func bind(settingID: String, action: @escaping @MainActor () -> Void) {
        actions[settingID] = action
        register(settingID)
    }

    func start() {
        // While a shortcut is being recorded, release all hotkeys so every key combination reaches the recorder.
        recordingObserver = NotificationCenter.default.addObserver(forName: .shortcutRecordingChanged, object: nil, queue: .main) { [weak self] note in
            let recording = note.userInfo?["recording"] as? Bool ?? false
            MainActor.assumeIsolated { self?.setPaused(recording) }
        }
        subscription = store.changes
            .filter { $0.hasPrefix("hotkey.") }
            .sink { [weak self] id in MainActor.assumeIsolated { self?.register(id) } }
    }

    /// A shortcut that exists only for a moment (Esc during a recording countdown). Pass nil to remove it. It uses the same
    /// manager as the others: a second one would take over their key presses.
    func setTemporary(_ shortcut: KeyShortcut, name: String, action: (@MainActor () -> Void)?) {
        guard let action else { manager.unregister(name: name); return }
        do {
            try manager.register(name: name, shortcut: shortcut, handler: action)
        } catch {
            log.error("Temporary hotkey \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func setPaused(_ pause: Bool) {
        guard pause != paused else { return }
        paused = pause
        if pause { manager.unregisterAll() } else { for id in actions.keys { register(id) } }
    }

    private func register(_ settingID: String) {
        guard !paused else { return }     // re-registered when recording ends
        guard let action = actions[settingID] else { return }
        guard let shortcut = store.shortcut(settingID) else {
            manager.unregister(name: settingID)          // the user cleared it
            return
        }
        do {
            try manager.register(name: settingID, shortcut: shortcut, handler: action)
        } catch HotkeyError.alreadyInUse {
            manager.unregister(name: settingID)
            store.setNote("\(shortcut.displayString) is already used by another app or macOS. Choose a different shortcut.", for: settingID)
        } catch {
            manager.unregister(name: settingID)
            store.setNote("This shortcut could not be registered.", for: settingID)
            log.error("Hotkey \(settingID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }
}
