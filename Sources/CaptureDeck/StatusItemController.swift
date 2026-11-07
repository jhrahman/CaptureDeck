import AppKit
import CaptureEngine
import DesignSystem

/// Owns the menu bar icon and its menu.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let appearance: AppearanceController
    private let coordinator: CaptureCoordinator

    init(appearance: AppearanceController, coordinator: CaptureCoordinator) {
        self.appearance = appearance
        self.coordinator = coordinator
        super.init()
        statusItem.button?.image = Self.menuBarImage()
        statusItem.button?.toolTip = "CaptureDeck"
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // One item per registered capture mode, showing its shortcut.
        for mode in coordinator.modes {
            let item = NSMenuItem(title: mode.title, action: #selector(capture(_:)), keyEquivalent: mode.defaultShortcut?.keyLabel ?? "")
            item.target = self
            item.representedObject = mode.id
            if let shortcut = mode.defaultShortcut {
                var mask: NSEvent.ModifierFlags = []
                if shortcut.modifiers.contains(.command) { mask.insert(.command) }
                if shortcut.modifiers.contains(.option) { mask.insert(.option) }
                if shortcut.modifiers.contains(.control) { mask.insert(.control) }
                if shortcut.modifiers.contains(.shift) { mask.insert(.shift) }
                item.keyEquivalentModifierMask = mask
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for option in AppearancePreference.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == appearance.preference ? .on : .off
            submenu.addItem(item)
        }
        appearanceItem.submenu = submenu
        menu.addItem(appearanceItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit CaptureDeck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func capture(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        // Let the menu finish closing so it is not part of the screenshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [coordinator] in
            coordinator.run(modeID: id)
        }
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let option = AppearancePreference(rawValue: raw) else { return }
        appearance.set(option)
        rebuildMenu()
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
