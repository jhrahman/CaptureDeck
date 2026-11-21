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
    public func open(image: CapturedImage, title: String? = nil, startsSelected: Bool = true) {
        let name = title ?? suggestedName()
        let document = EditorDocument(original: image, title: name)
        document.startsWithFullSelection = startsSelected
        show(document)
    }

    /// The name a new capture gets: the "File name" setting from Settings > Output (the same one auto-save uses), so what the
    /// editor shows, and offers when saving, matches the files that auto-save writes.
    func suggestedName() -> String {
        let template = settings.string("capture.fileTemplate")
        let folder = saveFolder
        return FilenameTemplate.suggestedName(template: template) { name in
            ImageFileFormat.allCases.contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).appendingPathExtension($0.fileExtension).path) }
        }
    }

    /// The "Save folder" setting (Settings > Output).
    var saveFolder: URL {
        let path = settings.string("capture.saveFolder")
        return path.isEmpty ? (FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()))
                            : URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
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
        guard let image = ImageImport.image() else {
            let alert = NSAlert()
            alert.messageText = "There is no image on the clipboard"
            alert.informativeText = "Copy an image (or take a screenshot) first, then try again."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        open(image: image, title: "Pasted image")
    }

    /// Brings every open editor window to the front. Returns false if there are none.
    @discardableResult
    public func showEditors() -> Bool {
        guard !controllers.isEmpty else { openBlank(); return false }
        NSApp.activate(ignoringOtherApps: true)
        for controller in controllers { controller.window?.orderFrontRegardless() }
        controllers.last?.window?.makeKeyAndOrderFront(nil)
        return true
    }

    /// A new editor on an empty white canvas, so the editor can be opened with nothing captured yet
    /// (then paste, open or drop an image, or just draw).
    public func openBlank(width: Int = 1280, height: Int = 800) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return }
        open(image: CapturedImage(cgImage: image, scale: 1), title: "Untitled", startsSelected: false)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens files (for example images dropped on the capture panel) in new tabs.
    public func openImages(at urls: [URL]) { open(urls: urls) }

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
