import AppKit
import DesignSystem

/// Owns the menu bar icon and its menu.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let appearance: AppearanceController

    init(appearance: AppearanceController) {
        self.appearance = appearance
        super.init()
        statusItem.button?.image = Self.menuBarImage()
        statusItem.button?.toolTip = "CaptureDeck"
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

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
