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

    public func windowWillClose(_ notification: Notification) {
        ActivationPolicyManager.shared.release(self)
    }
}
