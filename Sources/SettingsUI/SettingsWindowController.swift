import AppKit
import Platform
import Settings
import SwiftUI

/// Opens (and re-uses) the Settings window.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let store: SettingsStore
    private var window: NSWindow?

    public init(store: SettingsStore) {
        self.store = store
        super.init()
    }

    public func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(store: store))
            let window = NSWindow(contentViewController: host)
            window.title = "CaptureDeck Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 660, height: 600))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("CaptureDeckSettings")
            if !window.setFrameUsingName("CaptureDeckSettings") { window.center() }
            self.window = window
        }
        ActivationPolicyManager.shared.retain(self)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing with edits that were not applied asks what to do with them.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard store.hasPending else { return true }
        let alert = NSAlert()
        alert.messageText = "Apply your changes?"
        alert.informativeText = "You changed \(store.pending.count) \(store.pending.count == 1 ? "setting" : "settings") but did not press Apply."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: self.store.applyPending(); sender.close()
            case .alertSecondButtonReturn: self.store.discardPending(); sender.close()
            default: break
            }
        }
        return false
    }

    public func windowWillClose(_ notification: Notification) {
        ActivationPolicyManager.shared.release(self)
    }
}
