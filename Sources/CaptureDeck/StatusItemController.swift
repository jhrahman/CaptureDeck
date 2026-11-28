import AppKit
import CaptureEngine
import Combine
import CoreModels
import DesignSystem
import EditorUI
import RecordingUI
import Settings

/// Owns the menu bar icon and its menu. The menu is rebuilt whenever a shortcut or the theme changes.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let coordinator: CaptureCoordinator
    private let recording: RecordingCoordinator
    private let panel: CapturePanelController
    private let store: SettingsStore
    private let editor: EditorStore
    private let openSettings: () -> Void
    private var toggleItem: NSMenuItem?
    private var subscription: AnyCancellable?
    private var appearanceObservation: NSKeyValueObservation?
    private var blinkChanges: AnyCancellable?
    private let blinkingDot = MenuBarBlinkingDot()

    init(coordinator: CaptureCoordinator, recording: RecordingCoordinator, panel: CapturePanelController, store: SettingsStore, editor: EditorStore, openSettings: @escaping () -> Void) {
        self.coordinator = coordinator
        self.recording = recording
        self.panel = panel
        self.store = store
        self.editor = editor
        self.openSettings = openSettings
        super.init()
        updateIcon()
        // The menu bar turns light or dark with the wallpaper and the system theme; the recording icon has to follow.
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateIcon() } }
        }
        statusItem.button?.toolTip = "CaptureDeck"
        rebuildMenu()
        recording.onStateChange = { [weak self] in self?.recordingStateChanged() }
        // The blink follows the Settings window as soon as Apply is pressed, also in the middle of a recording.
        blinkChanges = store.changes
            .filter { [SettingID.recMenuBarBlink, SettingID.recBlinkStyle, SettingID.recBlinkSpeed].contains($0) }
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateIcon() } }
        recording.onMenuBarTime = { [weak self] time in self?.showRecordingTime(time) }
        subscription = store.changes
            .filter { $0.hasPrefix("hotkey.") || $0 == SettingID.appearance || $0 == SettingID.recSource }
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.rebuildMenu() } }
    }

    private func applyShortcut(_ shortcut: KeyShortcut?, to item: NSMenuItem) {
        guard let shortcut else { return }
        item.keyEquivalent = shortcut.keyLabel.lowercased()
        var mask: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { mask.insert(.command) }
        if shortcut.modifiers.contains(.option) { mask.insert(.option) }
        if shortcut.modifiers.contains(.control) { mask.insert(.control) }
        if shortcut.modifiers.contains(.shift) { mask.insert(.shift) }
        item.keyEquivalentModifierMask = mask
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        // The app's name and version, as the first line of the menu.
        let about = NSMenuItem(title: AppInfo.nameAndVersion, action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(.separator())

        // One item per registered capture mode, showing its current shortcut.
        for mode in coordinator.modes {
            let item = NSMenuItem(title: mode.title, action: #selector(capture(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.id
            applyShortcut(store.shortcut(SettingID.hotkey(mode.id)), to: item)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        addRecordingItems(to: menu)
        menu.addItem(.separator())

        // The editor: open any image, edit what is on the clipboard, or come back to open editors.
        let openImage = NSMenuItem(title: "Open Image in Editor…", action: #selector(openImageInEditor), keyEquivalent: "")
        openImage.target = self
        menu.addItem(openImage)
        let pasteImage = NSMenuItem(title: "Edit Image from Clipboard", action: #selector(editClipboardImage), keyEquivalent: "")
        pasteImage.target = self
        menu.addItem(pasteImage)
        let showEditors = NSMenuItem(title: "Show Editor", action: #selector(showOpenEditors), keyEquivalent: "")
        showEditors.target = self
        showEditors.tag = 77
        menu.addItem(showEditors)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Hide Capture Panel", action: #selector(togglePanel), keyEquivalent: "")
        toggle.target = self
        applyShortcut(store.shortcut(SettingID.togglePanelHotkey), to: toggle)
        toggleItem = toggle
        menu.addItem(toggle)

        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = store.string(SettingID.appearance)
        for option in AppearancePreference.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option.rawValue == current ? .on : .off
            submenu.addItem(item)
        }
        appearanceItem.submenu = submenu
        menu.addItem(appearanceItem)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit CaptureDeck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func addRecordingItems(to menu: NSMenu) {
        func add(_ title: String, _ action: Selector, shortcut: String, source: RecordingSourceKind? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = source?.rawValue
            applyShortcut(store.shortcut(shortcut), to: item)
            menu.addItem(item)
        }
        switch recording.state {
        case .idle:
            let preferred = store.string(SettingID.recSource)
            for source in RecordingSourceKind.allCases {
                // The Start / stop shortcut belongs to the default source, unless that source has its own.
                let own = SettingID.recordSourceHotkey(source.rawValue)
                add(source.menuTitle, #selector(record(_:)),
                    shortcut: store.shortcut(own) == nil && source.rawValue == preferred ? SettingID.recordHotkey : own, source: source)
            }
            if recording.hasLastRegion { add("Record Last Region", #selector(recordLastRegion), shortcut: SettingID.recordLastRegionHotkey) }
        case .recording, .paused:
            add("Stop Recording", #selector(stopRecording), shortcut: SettingID.recordHotkey)
            add(recording.state == .paused ? "Resume Recording" : "Pause Recording", #selector(pauseRecording), shortcut: SettingID.recordPauseHotkey)
            let again = NSMenuItem(title: "Start Over", action: #selector(restartRecording), keyEquivalent: "")
            again.target = self
            menu.addItem(again)
        case .starting:
            let item = NSMenuItem(title: "Cancel Recording", action: #selector(cancelRecording), keyEquivalent: "")
            item.target = self
            applyShortcut(store.shortcut(SettingID.recordHotkey), to: item)
            menu.addItem(item)
        case .finishing:
            let item = NSMenuItem(title: "Finishing Recording…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    private func showRecordingTime(_ time: String?) {
        guard let button = statusItem.button else { return }
        let title = time.map { " \($0)" } ?? ""
        // The icon moves within the button as the title changes width, so the blinking dot is put back on it afterwards.
        defer { DispatchQueue.main.async { [blinkingDot] in blinkingDot.place() } }
        guard button.title != title else { return }
        statusItem.length = time == nil ? NSStatusItem.squareLength : NSStatusItem.variableLength
        button.imagePosition = time == nil ? .imageOnly : .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.title = title
    }

    /// The menu bar icon shows a red dot while a recording runs, and pause bars while it is paused.
    private func recordingStateChanged() {
        updateIcon()
        rebuildMenu()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let icon: MenuBarIcon = switch recording.state {
        case .recording: .recording
        case .paused: .paused
        case .idle, .starting, .finishing: .idle
        }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if icon == .recording, store.bool(SettingID.recMenuBarBlink), let base = icon.bundledImage(darkMenuBar: dark) {
            let blink = RecordingBlink(style: BlinkStyle(rawValue: store.string(SettingID.recBlinkStyle)) ?? .smooth,
                                       period: Double(store.string(SettingID.recBlinkSpeed)) ?? 1.4)
            blinkingDot.show(blink, base: base, key: icon.resourceName(darkMenuBar: dark), on: button)
        } else {
            blinkingDot.stop()
            button.image = icon.image(darkMenuBar: dark)
        }
    }

    @objc private func record(_ sender: NSMenuItem) {
        guard let source = (sender.representedObject as? String).flatMap(RecordingSourceKind.init(rawValue:)) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [recording] in recording.start(source) }
    }
    @objc private func recordLastRegion() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [recording] in recording.startLastRegion() }
    }
    @objc private func restartRecording() { recording.restart() }
    @objc private func cancelRecording() { recording.cancelStart() }
    @objc private func stopRecording() { recording.stop() }
    @objc private func pauseRecording() { recording.togglePause() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: 77)?.title = editor.hasOpenEditors ? "Show Editor" : "Open Editor"
        toggleItem?.title = panel.isVisible ? "Hide Capture Panel" : "Show Capture Panel"
    }

    @objc private func openImageInEditor() { editor.openDocument(nil) }
    @objc private func editClipboardImage() { editor.pasteAsNewTab(nil) }
    @objc private func showOpenEditors() { editor.showEditors() }
    @objc private func showSettings() { openSettings() }
    @objc private func togglePanel() { panel.toggle() }

    @objc private func capture(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        // Let the menu finish closing so it is not part of the screenshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [coordinator] in
            coordinator.run(modeID: id)
        }
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        store.set(raw, for: SettingID.appearance)
    }
}
