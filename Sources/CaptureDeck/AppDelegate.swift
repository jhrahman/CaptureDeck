import AppKit
import CaptureEngine
import Combine
import CoreModels
import DesignSystem
import EditorUI
import Platform
import Settings
import SettingsUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appearance = AppearanceController()
    private var store: SettingsStore!
    private var coordinator: CaptureCoordinator!
    private var recording: RecordingCoordinator!
    private var hotkeys: HotkeyBindings!
    private var panel: CapturePanelController!
    private var editor: EditorStore!
    private var settingsWindow: SettingsWindowController!
    private var statusItem: StatusItemController!
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Composition root. Capture modes are registered here; hotkeys, menu items, panel buttons and
        // their settings are all generated from this list.
        let lastCapture = LastCaptureStore()
        let overlay = RegionSelector(style: OverlayStyle(accent: Theme.accent)) { [weak self] in self?.overlayOptions() ?? OverlayOptions() }
        let modes: [any CaptureMode] = [
            FullScreenCaptureMode(),
            AllDisplaysCaptureMode(),
            RegionCaptureMode(selector: overlay),
            ActiveWindowCaptureMode(selector: overlay),
            ScrollingCaptureMode(selector: overlay),
            WindowObjectCaptureMode(selector: overlay),
            FreehandCaptureMode(selector: overlay),
            FixedSizeCaptureMode(
                presets: { [weak self] in FixedSizeText.parseList(self?.store.string(SettingID.fixedPresets) ?? "") },
                selector: overlay),
            RepeatLastCaptureMode(store: lastCapture),
            TextCaptureMode(selector: overlay),
        ]

        store = SettingsStore(registry: AppSettings.registry(modes: modes))
        coordinator = CaptureCoordinator(modes: modes, lastCapture: lastCapture, store: store)
        coordinator.textDelivery = TextCaptureDelivery(store: store)
        recording = RecordingCoordinator(store: store, selector: overlay)
        recording.isScreenshotRunning = { [weak coordinator] in coordinator?.isCapturing ?? false }
        settingsWindow = SettingsWindowController(store: store)
        editor = EditorStore(settings: store)
        editor.openSettings = { [weak self] in self?.settingsWindow.show() }

        appearance.set(AppearancePreference(rawValue: store.string(SettingID.appearance)) ?? .system)
        store.changes.filter { $0 == SettingID.appearance }.sink { [weak self] _ in
            guard let self else { return }
            self.appearance.set(AppearancePreference(rawValue: self.store.string(SettingID.appearance)) ?? .system)
        }.store(in: &subscriptions)

        panel = CapturePanelController(
            modes: modes, store: store,
            extras: { [weak self] in
                guard let self, self.store.bool(SettingID.panelEditorButtons) else { return [] }
                return [PanelExtra(id: "openImage", symbol: "folder", title: "Open Image in Editor…") { self.editor.openDocument(nil) },
                 PanelExtra(id: "clipboard", symbol: "doc.on.clipboard", title: "Edit Image from Clipboard") { self.editor.pasteAsNewTab(nil) }]
            },
            recordButton: { [weak self] in
                PanelExtra(id: "record", symbol: "record.circle", title: "Record Screen") { self?.recording.toggle() }
            },
            onDropImages: { [weak self] urls in self?.editor.openImages(at: urls) }
        ) { [coordinator] id in coordinator?.run(modeID: id) }
        coordinator.beforeCapture = { [panel, editor] in await panel?.suspend(); await editor?.suspendWindows() }
        coordinator.afterCapture = { [panel, editor, recording] in
            if recording?.isActive != true { panel?.resume() }        // it must not reappear in a running recording
            editor?.resumeWindows()
        }
        recording.beforeRecording = { [panel] in await panel?.suspend() }
        recording.afterRecording = { [panel] in panel?.resume() }
        coordinator.openInEditor = { [editor] image in editor?.open(image: image) }

        statusItem = StatusItemController(coordinator: coordinator, recording: recording, panel: panel, store: store, editor: editor) { [weak self] in
            self?.settingsWindow.show()
        }

        hotkeys = HotkeyBindings(store: store)
        for mode in modes {
            hotkeys.bind(settingID: SettingID.hotkey(mode.id)) { [coordinator] in coordinator?.run(modeID: mode.id) }
        }
        hotkeys.bind(settingID: SettingID.recordHotkey) { [recording] in recording?.toggle() }
        hotkeys.bind(settingID: SettingID.recordPauseHotkey) { [recording] in recording?.togglePause() }
        for source in RecordingSourceKind.allCases {
            hotkeys.bind(settingID: SettingID.recordSourceHotkey(source.rawValue)) { [recording] in recording?.start(source) }
        }
        hotkeys.bind(settingID: SettingID.recordLastRegionHotkey) { [recording] in recording?.startLastRegion() }
        recording.setEscapeHandler = { [hotkeys] action in
            hotkeys?.setTemporary(KeyShortcut(keyCode: 53, modifiers: [], keyLabel: "Esc"), name: "recording.cancelCountdown", action: action)
        }
        hotkeys.bind(settingID: SettingID.togglePanelHotkey) { [panel] in panel?.toggle() }
        hotkeys.start()

        panel.showAtLaunch(minimized: store.bool(SettingID.startMinimized))
        recording.recoverUnsaved()

        syncLoginItem()
        store.changes.filter { $0 == SettingID.launchAtLogin }.sink { [weak self] _ in self?.applyLoginItem() }.store(in: &subscriptions)
        // Applying a new capture sound plays it once, so you hear what you chose.
        store.changes.filter { $0 == SettingID.soundName }.sink { [weak self] _ in
            guard let self else { return }
            NSSound(named: NSSound.Name(self.store.string(SettingID.soundName)))?.play()
        }.store(in: &subscriptions)
    }

    /// A running recording is closed properly before quitting, never cut off.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recording?.isActive == true else { return .terminateNow }
        Task {
            await recording.finishForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Launch at login

    private var changingLoginItem = false

    /// The Settings window should show what macOS really has (the user can also change it in System Settings).
    private func syncLoginItem() {
        let status = LoginItem.status
        changingLoginItem = true
        store.set(status == .enabled || status == .requiresApproval, for: SettingID.launchAtLogin)
        changingLoginItem = false
        store.setNote(LoginItem.explanation(for: status), for: SettingID.launchAtLogin)
    }

    private func applyLoginItem() {
        guard !changingLoginItem else { return }
        do {
            try LoginItem.setEnabled(store.bool(SettingID.launchAtLogin))
            store.setNote(LoginItem.explanation(for: LoginItem.status), for: SettingID.launchAtLogin)
        } catch {
            // Put the switch back to what macOS really has, and say why.
            let actual = LoginItem.status
            changingLoginItem = true
            store.set(actual == .enabled || actual == .requiresApproval, for: SettingID.launchAtLogin)
            changingLoginItem = false
            store.setNote("macOS did not allow this: \(error.localizedDescription)", for: SettingID.launchAtLogin)
        }
    }

    /// Selection overlay behavior from Settings, read each time an overlay opens.
    private func overlayOptions() -> OverlayOptions {
        guard let store else { return OverlayOptions() }
        return OverlayOptions(
            dimAlpha: CGFloat(store.double(SettingID.dimLevel)),
            showMagnifier: store.bool(SettingID.magnifier),
            magnifierZoom: Int(store.string(SettingID.magnifierZoom)) ?? 8,
            lastFixedSize: FixedSizeText.parse(store.string(SettingID.fixedSizeLast)),
            onFixedSizeChanged: { [weak store] size in store?.set(FixedSizeText.format(size), for: SettingID.fixedSizeLast) })
    }
}
