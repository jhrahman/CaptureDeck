import AppKit
import CaptureEngine
import Combine
import CoreModels
import DesignSystem
import EditorUI
import Settings

/// Owns the menu bar icon and its menu. The menu is rebuilt whenever a shortcut or the theme changes.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let coordinator: CaptureCoordinator
    private let panel: CapturePanelController
    private let store: SettingsStore
    private let editor: EditorStore
    private let openSettings: () -> Void
    private var toggleItem: NSMenuItem?
    private var subscription: AnyCancellable?

    init(coordinator: CaptureCoordinator, panel: CapturePanelController, store: SettingsStore, editor: EditorStore, openSettings: @escaping () -> Void) {
        self.coordinator = coordinator
        self.panel = panel
        self.store = store
        self.editor = editor
        self.openSettings = openSettings
        super.init()
        statusItem.button?.image = Self.menuBarImage()
        statusItem.button?.toolTip = "CaptureDeck"
        rebuildMenu()
        subscription = store.changes
            .filter { $0.hasPrefix("hotkey.") || $0 == SettingID.appearance }
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

    /// Brand template image from the app bundle; SF Symbol fallback when run outside a bundle (`swift run`).
    private static func menuBarImage() -> NSImage {
        let image = NSImage(named: "menubarTemplate")
            ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "CaptureDeck")
            ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true  // macOS tints it for light, dark and highlighted states
        return image
    }
}
