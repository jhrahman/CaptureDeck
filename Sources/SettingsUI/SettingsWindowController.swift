import AppKit
import DesignSystem
import Platform
import Settings
import SwiftUI

/// Opens (and re-uses) the Settings window.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let store: SettingsStore
    private var window: NSWindow?
    private static let defaultSize = NSSize(width: 900, height: 660)
    private static let minimumSize = NSSize(width: 820, height: 580)

    public init(store: SettingsStore) {
        self.store = store
        super.init()
    }

    public func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(store: store))
            let window = NSWindow(contentViewController: host)
            window.title = "CaptureDeck Settings"
            // The brand sidebar runs the full height, under the close buttons; the title is kept for the window menu and VoiceOver.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.setContentSize(Self.defaultSize)
            window.contentMinSize = Self.minimumSize
            window.isReleasedWhenClosed = false
            window.isOpaque = false                  // glass: the desktop shows through the window
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.delegate = self
            window.setFrameAutosaveName("CaptureDeckSettings")
            if !window.setFrameUsingName("CaptureDeckSettings") { window.center() }
            // A size remembered from the earlier, narrower window must not squeeze this one.
            if window.contentLayoutRect.width < Self.minimumSize.width || window.frame.height < Self.minimumSize.height {
                window.setContentSize(Self.defaultSize)
                window.center()
            }
            self.window = window
        }
        ActivationPolicyManager.shared.retain(self)
        let wasHidden = window?.isVisible != true
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // The window opens with nothing focused. Otherwise the search box takes the keyboard, and with it the Return key.
        if wasHidden {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.window?.makeFirstResponder(nil) }
        }
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
