import AppKit
import Combine
import CoreModels
import EditorEngine
import Platform
import SwiftUI
import UniformTypeIdentifiers

/// One editor window (one tab): toolbar, canvas, and the actions behind the menus.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation, NSToolbarItemValidation {
    let editorDocument: EditorDocument
    weak var store: EditorStore?
    private let viewController: EditorViewController
    private var cancellables = Set<AnyCancellable>()
    private var closeConfirmed = false

    static let tabbingIdentifier = "app.capturedeck.editor"

    init(editorDocument: EditorDocument, store: EditorStore) {
        self.editorDocument = editorDocument
        self.store = store
        self.viewController = EditorViewController(document: editorDocument, settings: store.settings)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentViewController = viewController
        window.setContentSize(NSSize(width: 1100, height: 760))
        window.minSize = NSSize(width: 520, height: 340)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.title = editorDocument.title
        window.center()
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "app.capturedeck.editor.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        viewController.onToolChanged = { [weak self] descriptor in self?.toolbarToolGroup?.selectedIndex = EditorToolRegistry.descriptors.firstIndex(of: descriptor) ?? 0 }
        viewController.scrollView.onFilesDropped = { [weak self] urls in self?.store?.open(urls: urls) }
        editorDocument.$title.sink { [weak window] in window?.title = $0 }.store(in: &cancellables)
        editorDocument.$fileURL.sink { [weak window] in window?.representedURL = $0 }.store(in: &cancellables)
        editorDocument.$undoNames.combineLatest(editorDocument.$redoNames).sink { [weak self] _ in
            self?.window?.isDocumentEdited = self?.editorDocument.isDirty ?? false
            self?.window?.toolbar?.validateVisibleItems()
        }.store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Actions (menus and toolbar)

    @objc func performUndo(_ sender: Any?) { editorDocument.undo() }
    @objc func performRedo(_ sender: Any?) { editorDocument.redo() }
    @objc func rotateRight(_ sender: Any?) { editorDocument.apply(.rotate(quarterTurns: 1)) }
    @objc func rotateLeft(_ sender: Any?) { editorDocument.apply(.rotate(quarterTurns: 3)) }
    @objc func flipHorizontal(_ sender: Any?) { editorDocument.apply(.flipHorizontal) }
    @objc func flipVertical(_ sender: Any?) { editorDocument.apply(.flipVertical) }
    @objc func zoomIn(_ sender: Any?) { viewController.scrollView.zoom(by: 1.25) }
    @objc func zoomOut(_ sender: Any?) { viewController.scrollView.zoom(by: 0.8) }
    @objc func zoomFit(_ sender: Any?) { viewController.scrollView.zoomToFit() }
    @objc func zoomActual(_ sender: Any?) { viewController.scrollView.zoomActualSize() }

    /// Copies the selected area if there is one, otherwise the whole picture.
    @objc func copyImage(_ sender: Any?) {
        let image = editorDocument.selectionImage() ?? editorDocument.flattenedImage()
        do { try ClipboardManager().copy(image) } catch { NSSound.beep() }
    }

    // MARK: Resize, canvas size, rotate by angle (dialogs)

    private var backgroundFill: RGBAColor { RGBAColor(hex: store?.settings.string("editor.backgroundFill") ?? "") ?? .white }

    private func present<Content: View>(_ makeContent: (@escaping () -> Void) -> Content) {
        guard let window else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let dismiss = { [weak window, weak sheet] in
            if let window, let sheet { window.endSheet(sheet) }
        }
        sheet.contentViewController = NSHostingController(rootView: makeContent(dismiss))
        window.beginSheet(sheet)
    }

    @objc func resizeImage(_ sender: Any?) {
        let size = editorDocument.workingImage.pixelSize
        let keep = store?.settings.bool("editor.resizeKeepProportions") ?? true
        present { dismiss in
            ResizeSheet(original: (Int(size.width), Int(size.height)), keepProportions: keep,
                        onApply: { [weak self] w, h in dismiss(); self?.editorDocument.apply(.resize(width: w, height: h)) },
                        onCancel: dismiss)
        }
    }

    /// Quick resize from the menu; the percentage is the menu item's tag.
    @objc func resizeByPercent(_ sender: NSMenuItem) {
        let size = editorDocument.workingImage.pixelSize
        let target = ResizeMath.size(from: (Int(size.width), Int(size.height)), percent: Double(sender.tag))
        guard ResizeMath.isValid(width: target.width, height: target.height) else { NSSound.beep(); return }
        editorDocument.apply(.resize(width: target.width, height: target.height))
    }

    @objc func canvasSize(_ sender: Any?) {
        let size = editorDocument.workingImage.pixelSize
        let fill = backgroundFill
        present { dismiss in
            CanvasSizeSheet(original: (Int(size.width), Int(size.height)), fill: fill,
                            onApply: { [weak self] w, h, anchor, color in
                                dismiss(); self?.editorDocument.apply(.canvasSize(width: w, height: h, anchor: anchor, fill: color))
                            }, onCancel: dismiss)
        }
    }

    @objc func rotateImageByAngle(_ sender: Any?) {
        let fill = backgroundFill
        present { dismiss in
            RotateSheet(fill: fill,
                        onApply: { [weak self] degrees, color in dismiss(); self?.editorDocument.apply(.rotateByAngle(degrees: degrees, fill: color)) },
                        onCancel: dismiss)
        }
    }

    @objc func selectEverything(_ sender: Any?) { editorDocument.selectAll() }
    @objc func deselect(_ sender: Any?) { editorDocument.clearSelection() }
    @objc func cropToSelection(_ sender: Any?) { editorDocument.cropToSelection() }

    @objc func duplicateSelection(_ sender: Any?) {
        guard let image = editorDocument.selectionImage() else { return }
        store?.open(image: image, title: "\(editorDocument.title) selection")
    }

    @objc func chooseTool(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        viewController.selectTool(id: id)
    }

    @objc func chooseToolFromToolbar(_ sender: NSToolbarItemGroup) {
        let descriptors = EditorToolRegistry.descriptors
        guard descriptors.indices.contains(sender.selectedIndex) else { return }
        viewController.selectTool(id: descriptors[sender.selectedIndex].id)
    }

    @objc func saveDocument(_ sender: Any?) { save { _ in } }
    @objc func saveDocumentAs(_ sender: Any?) { saveAs { _ in } }

    // MARK: Saving

    /// Save writes to the file this editorDocument was last saved to; otherwise it asks where.
    /// (Files opened from disk are never overwritten silently: they go through Save As.)
    func save(completion: @escaping (Bool) -> Void) {
        if let url = editorDocument.fileURL { write(to: url, completion: completion) } else { saveAs(completion: completion) }
    }

    func saveAs(completion: @escaping (Bool) -> Void) {
        guard let window else { return completion(false) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = editorDocument.title
        panel.directoryURL = editorDocument.fileURL?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, var url = panel.url else { return completion(false) }
            if ImageFileFormat(fileExtension: url.pathExtension) == nil { url.appendPathExtension("png") }
            self?.write(to: url, completion: completion)
        }
    }

    private func write(to url: URL, completion: (Bool) -> Void) {
        let format = ImageFileFormat(fileExtension: url.pathExtension) ?? .png
        do {
            try FileSaver().write(editorDocument.flattenedImage(), to: url, format: format)
            editorDocument.fileURL = url
            editorDocument.title = url.deletingPathExtension().lastPathComponent
            editorDocument.markSaved()
            window?.isDocumentEdited = false
            completion(true)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not save the image"
            alert.informativeText = "Check that CaptureDeck can write to \(url.deletingLastPathComponent().path)."
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            completion(false)
        }
    }

    // MARK: Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let ask = store?.settings.bool("editor.askBeforeDiscard") ?? true
        guard editorDocument.isDirty, ask, !closeConfirmed else { return true }

        let alert = NSAlert()
        alert.messageText = "Save changes to “\(editorDocument.title)”?"
        alert.informativeText = "Your edits will be lost if you don’t save them."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.save { saved in if saved { self.closeConfirmed = true; sender.close() } }
            case .alertSecondButtonReturn:
                self.closeConfirmed = true
                sender.close()
            default: break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) { store?.controllerDidClose(self) }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(performUndo(_:)):
            item.title = editorDocument.undoName.map { "Undo \($0)" } ?? "Undo"
            return editorDocument.canUndo
        case #selector(performRedo(_:)):
            item.title = editorDocument.redoName.map { "Redo \($0)" } ?? "Redo"
            return editorDocument.canRedo
        case #selector(copyImage(_:)):
            item.title = editorDocument.selection == nil ? "Copy Image" : "Copy Selection"
            return true
        case #selector(deselect(_:)), #selector(cropToSelection(_:)), #selector(duplicateSelection(_:)):
            return editorDocument.selection != nil
        case #selector(chooseTool(_:)):
            item.state = (item.representedObject as? String) == viewController.activeTool.descriptor.id ? .on : .off
            return true
        default: return true
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .undo: editorDocument.canUndo
        case .redo: editorDocument.canRedo
        default: true
        }
    }

    // MARK: Toolbar

    private struct ToolbarEntry {
        let id: NSToolbarItem.Identifier
        let label: String
        let symbols: [String]
        let action: Selector
    }

    private static let entries: [ToolbarEntry] = [
        .init(id: .cropSelection, label: "Crop to Selection", symbols: ["crop"], action: #selector(cropToSelection(_:))),
        .init(id: .undo, label: "Undo", symbols: ["arrow.uturn.backward"], action: #selector(performUndo(_:))),
        .init(id: .redo, label: "Redo", symbols: ["arrow.uturn.forward"], action: #selector(performRedo(_:))),
        .init(id: .rotateLeft, label: "Rotate Left", symbols: ["rotate.left", "arrow.counterclockwise"], action: #selector(rotateLeft(_:))),
        .init(id: .rotateRight, label: "Rotate Right", symbols: ["rotate.right", "arrow.clockwise"], action: #selector(rotateRight(_:))),
        .init(id: .flipH, label: "Flip Horizontal", symbols: ["flip.horizontal", "arrow.left.and.right"], action: #selector(flipHorizontal(_:))),
        .init(id: .flipV, label: "Flip Vertical", symbols: ["arrow.up.and.down"], action: #selector(flipVertical(_:))),
        .init(id: .zoomOut, label: "Zoom Out", symbols: ["minus.magnifyingglass"], action: #selector(zoomOut(_:))),
        .init(id: .zoomIn, label: "Zoom In", symbols: ["plus.magnifyingglass"], action: #selector(zoomIn(_:))),
        .init(id: .zoomFit, label: "Fit to Window", symbols: ["arrow.up.left.and.down.right.magnifyingglass", "rectangle.expand.vertical"], action: #selector(zoomFit(_:))),
        .init(id: .zoomActual, label: "Actual Size", symbols: ["1.magnifyingglass"], action: #selector(zoomActual(_:))),
        .init(id: .copy, label: "Copy", symbols: ["doc.on.doc"], action: #selector(copyImage(_:))),
        .init(id: .save, label: "Save", symbols: ["square.and.arrow.down"], action: #selector(saveDocument(_:))),
    ]

    private var toolbarToolGroup: NSToolbarItemGroup?

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.tools, .space, .undo, .redo, .space, .cropSelection, .rotateLeft, .rotateRight, .flipH, .flipV, .space,
         .zoomOut, .zoomIn, .zoomFit, .zoomActual, .flexibleSpace, .copy, .save]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == .tools {
            let descriptors = EditorToolRegistry.descriptors
            let images = descriptors.map { d in NSImage(systemSymbolName: d.symbol, accessibilityDescription: d.title) ?? NSImage() }
            let group = NSToolbarItemGroup(itemIdentifier: identifier, images: images, selectionMode: .selectOne,
                                           labels: descriptors.map(\.title), target: self, action: #selector(chooseToolFromToolbar(_:)))
            group.label = "Tools"
            group.paletteLabel = "Tools"
            group.selectedIndex = descriptors.firstIndex(of: viewController.activeTool.descriptor) ?? 0
            for (item, d) in zip(group.subitems, descriptors) { item.toolTip = "\(d.title)  (\(d.key.uppercased()))" }
            toolbarToolGroup = group
            return group
        }
        guard let entry = Self.entries.first(where: { $0.id == identifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = entry.label
        item.paletteLabel = entry.label
        item.toolTip = entry.label
        item.image = entry.symbols.lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: entry.label) }.first
        item.target = self
        item.action = entry.action
        item.isBordered = true
        return item
    }
}

private extension NSToolbarItem.Identifier {
    static let tools = Self("tools")
    static let cropSelection = Self("cropSelection")
    static let undo = Self("undo")
    static let redo = Self("redo")
    static let rotateLeft = Self("rotateLeft")
    static let rotateRight = Self("rotateRight")
    static let flipH = Self("flipH")
    static let flipV = Self("flipV")
    static let zoomOut = Self("zoomOut")
    static let zoomIn = Self("zoomIn")
    static let zoomFit = Self("zoomFit")
    static let zoomActual = Self("zoomActual")
    static let copy = Self("copy")
    static let save = Self("save")
}
