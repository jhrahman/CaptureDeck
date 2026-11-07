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
            RegionCaptureMode(selector: overlay),
            ActiveWindowCaptureMode(),
            WindowObjectCaptureMode(selector: overlay),
            FreehandCaptureMode(selector: overlay),
            FixedSizeCaptureMode(
                presets: { [weak self] in FixedSizeText.parseList(self?.store.string(SettingID.fixedPresets) ?? "") },
                selector: overlay),
            RepeatLastCaptureMode(store: lastCapture),
        ]

        store = SettingsStore(registry: AppSettings.registry(modes: modes))
        coordinator = CaptureCoordinator(modes: modes, lastCapture: lastCapture, store: store)
        settingsWindow = SettingsWindowController(store: store)
        editor = EditorStore(settings: store)
        editor.openSettings = { [weak self] in self?.settingsWindow.show() }

        appearance.set(AppearancePreference(rawValue: store.string(SettingID.appearance)) ?? .system)
        store.changes.filter { $0 == SettingID.appearance }.sink { [weak self] _ in
            guard let self else { return }
            self.appearance.set(AppearancePreference(rawValue: self.store.string(SettingID.appearance)) ?? .system)
        }.store(in: &subscriptions)

        panel = CapturePanelController(modes: modes, store: store) { [coordinator] id in coordinator?.run(modeID: id) }
        coordinator.beforeCapture = { [panel, editor] in await panel?.suspend(); await editor?.suspendWindows() }
        coordinator.afterCapture = { [panel, editor] in panel?.resume(); editor?.resumeWindows() }
        coordinator.openInEditor = { [editor] image in editor?.open(image: image) }

        statusItem = StatusItemController(coordinator: coordinator, panel: panel, store: store) { [weak self] in
            self?.settingsWindow.show()
        }

        hotkeys = HotkeyBindings(store: store)
        for mode in modes {
            hotkeys.bind(settingID: SettingID.hotkey(mode.id)) { [coordinator] in coordinator?.run(modeID: mode.id) }
        }
        hotkeys.bind(settingID: SettingID.togglePanelHotkey) { [panel] in panel?.toggle() }
        hotkeys.start()

        panel.showAtLaunch()
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
