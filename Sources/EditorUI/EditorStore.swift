import AppKit
import CoreModels
import EditorEngine
import Platform
import Settings
import UniformTypeIdentifiers

/// Owns every open editor window. Windows are grouped as native macOS tabs.
/// While any editor is open the app shows in the Dock with a full menu bar; with none open it is menu-bar only.
@MainActor
public final class EditorStore: NSObject {
    private var controllers: [EditorWindowController] = []
    let settings: SettingsStore
    /// Opens the Settings window (the editor menu's Settings… item).
    public var openSettings: (() -> Void)?

    public init(settings: SettingsStore) {
        self.settings = settings
        super.init()
        NSApp.mainMenu = EditorMenu.build(store: self)
    }

    @objc func showSettings(_ sender: Any?) { openSettings?() }

    public var hasOpenEditors: Bool { !controllers.isEmpty }

    // MARK: Opening

    /// Opens a capture (or any image) in a new tab. `title` defaults to a timestamped name.
    public func open(image: CapturedImage, title: String? = nil) {
        let name = title ?? FilenameTemplate.render(FilenameTemplate.defaultTemplate, date: Date())
        show(EditorDocument(original: image, title: name))
    }

    public func open(urls: [URL]) {
        for url in urls {
            guard let image = ImageImport.load(from: url) else { alertCannotOpen(url); continue }
            // By default Save does not overwrite a file opened from disk (no file URL until Save As);
            // the "Save writes back to opened files" setting turns that on.
            let writeBack = settings.bool("editor.saveOverwritesOpenedFile")
            show(EditorDocument(original: image, title: url.deletingPathExtension().lastPathComponent,
                                fileURL: writeBack ? url : nil))
        }
    }

    @objc public func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        open(urls: panel.urls)
    }

    @objc public func pasteAsNewTab(_ sender: Any?) {
        guard let image = ImageImport.image() else { NSSound.beep(); return }
        open(image: image, title: "Pasted image")
    }

    private func show(_ document: EditorDocument) {
        let controller = EditorWindowController(editorDocument: document, store: self)
        let existing = controllers.last?.window
        controllers.append(controller)

        ActivationPolicyManager.shared.retain(controller)
        if let existing, let window = controller.window {
            existing.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        } else {
            controller.showWindow(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func controllerDidClose(_ controller: EditorWindowController) {
        controllers.removeAll { $0 === controller }
        ActivationPolicyManager.shared.release(controller)
    }

    // MARK: Hiding during captures

    /// Editor windows are made invisible while a capture runs so they never appear in a screenshot.
    public func suspendWindows() async {
        guard hasOpenEditors else { return }
        for c in controllers { c.window?.alphaValue = 0 }
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    public func resumeWindows() {
        for c in controllers { c.window?.alphaValue = 1 }
    }

    private func alertCannotOpen(_ url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not open “\(url.lastPathComponent)”"
        alert.informativeText = "It is not an image CaptureDeck can read."
        alert.runModal()
    }
}
