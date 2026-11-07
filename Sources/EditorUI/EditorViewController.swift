import AppKit
import Combine
import DesignSystem
import EditorEngine
import Settings
import SwiftUI

/// The editor's content: the zoomable canvas and a status bar.
@MainActor
final class EditorViewController: NSViewController {
    let document: EditorDocument
    let scrollView = ZoomScrollView(frame: .zero)
    private let canvas = CanvasView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private var cancellables = Set<AnyCancellable>()
    private let settings: SettingsStore?
    private let tools = EditorToolRegistry.makeTools()
    private(set) var activeTool: any EditorTool
    /// Called when the active tool changes (to keep the toolbar in step).
    var onToolChanged: ((EditorToolDescriptor) -> Void)?
    private let optionsModel = ToolOptionsModel()
    private var optionsBar: NSHostingView<ToolOptionsView>?
    private var optionsHeight: NSLayoutConstraint?
    /// A burst of style edits (dragging a slider) becomes one undo step, committed shortly after the last edit.
    private var pendingStyleEdit: (original: [Annotation], work: DispatchWorkItem)?
    private var didInitialFit = false
    private var lastPixelSize = CGSize.zero
    /// The image on screen. (`@Published` notifies before the property changes, so never re-read the document here.)
    private var shownImage: CGImage?
    private var shownSelection: EditorSelection?

    init(document: EditorDocument, settings: SettingsStore?) {
        self.document = document
        self.settings = settings
        let preferred = settings?.string("editor.defaultTool")
        let tools = self.tools
        activeTool = tools.first { $0.descriptor.id == preferred } ?? tools[0]
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let container = NSView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = canvas

        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = Theme.textSecondary
        bar.addSubview(statusLabel)

        let options = NSHostingView(rootView: ToolOptionsView(model: optionsModel))
        options.translatesAutoresizingMaskIntoConstraints = false
        optionsBar = options
        let height = options.heightAnchor.constraint(equalToConstant: 38)
        optionsHeight = height

        container.addSubview(options)
        container.addSubview(scrollView)
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            options.topAnchor.constraint(equalTo: container.topAnchor),
            options.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            options.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            height,
            scrollView.topAnchor.constraint(equalTo: options.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 24),
            statusLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        show(document.workingImage.cgImage)

        canvas.activeTool = activeTool
        canvas.toolContext = { [weak self] in
            guard let self else { return ToolContext(document: EditorDocument(original: .placeholder, title: ""), zoom: 1, style: .default) }
            return ToolContext(document: self.document,
                               zoom: self.scrollView.magnification * (self.view.window?.backingScaleFactor ?? 2),
                               style: self.currentToolStyle())
        }
        canvas.previewProvider = { [weak self] in self?.activeTool.previewAnnotations ?? [] }
        canvas.onToolKey = { [weak self] key in self?.selectTool(key: key) ?? false }
        canvas.onCycleTool = { [weak self] backwards in self?.cycleTool(backwards: backwards) }
        canvas.showSelectionSize = settings?.bool("editor.showSelectionSize") ?? true

        document.$selection
            .sink { [weak self] selection in
                self?.shownSelection = selection       // the passed value is the new one; never re-read the document here
                self?.canvas.selection = selection
                self?.updateStatus()
            }
            .store(in: &cancellables)
        document.$annotations
            .sink { [weak self] list in
                self?.canvas.annotations = list
                self?.syncOptions(annotations: list)
            }
            .store(in: &cancellables)
        document.$selectedAnnotationIDs
            .sink { [weak self] ids in
                guard let self else { return }
                self.canvas.selectedAnnotationIDs = ids
                self.syncOptions(selectedIDs: ids)
            }
            .store(in: &cancellables)
        optionsModel.onStyleEdited = { [weak self] style in self?.styleEdited(style) }
        optionsModel.onAction = { [weak self] action in self?.perform(action) }
        syncOptions()

        settings?.changes
            .filter { $0 == "editor.showSelectionSize" }
            .sink { [weak self] _ in self?.canvas.showSelectionSize = self?.settings?.bool("editor.showSelectionSize") ?? true }
            .store(in: &cancellables)

        document.$workingImage
            .dropFirst()
            .sink { [weak self] image in self?.show(image.cgImage) }
            .store(in: &cancellables)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(zoomChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(canvas)      // so tool keys and Esc work straight away
    }

    // MARK: Tools

    func selectTool(id: String) {
        guard let tool = tools.first(where: { $0.descriptor.id == id }), tool !== activeTool else { return }
        activeTool.deactivate()
        activeTool = tool
        canvas.activeTool = tool
        onToolChanged?(tool.descriptor)
        syncOptions()
        canvas.needsDisplay = true
    }

    // MARK: Properties bar

    /// The look new shapes get: the tool's remembered style from Settings.
    private func currentToolStyle() -> AnnotationStyle {
        ToolStyleSetting.style(for: activeTool.descriptor, settings: settings)
    }

    /// Refreshes the bar. The values passed in are the new ones; `@Published` fires before the property changes,
    /// so the document is never re-read from inside the notification.
    private func syncOptions(annotations: [Annotation]? = nil, selectedIDs: [UUID]? = nil) {
        let all = annotations ?? document.annotations
        let ids = selectedIDs ?? document.selectedAnnotationIDs
        let selected = ids.compactMap { id in all.first { $0.id == id } }
        let descriptor = activeTool.descriptor

        optionsModel.selectionCount = selected.count
        optionsModel.hint = nil
        if let first = selected.first {
            // Editing objects: show (and change) their look.
            optionsModel.properties = descriptor.kind == .draw ? descriptor.styleProperties : StyleProperty.allCases
            optionsModel.style = first.style
            optionsModel.title = selected.count == 1 ? "Selected" : "\(selected.count) selected"
        } else if descriptor.kind == .draw {
            optionsModel.properties = descriptor.styleProperties
            optionsModel.style = currentToolStyle()
            optionsModel.title = descriptor.title
        } else {
            optionsModel.properties = []
            optionsModel.title = descriptor.title
            if descriptor.kind == .object { optionsModel.hint = "Click an object to select it. Drag to move it, or use the handles to resize." }
        }
        // The bar stays put for object and drawing tools, so the canvas does not jump when you select or deselect.
        let visible = descriptor.kind != .pixelSelection
        optionsHeight?.constant = visible ? 38 : 0
        optionsBar?.isHidden = !visible
    }

    /// The user changed something in the bar: restyle the selected objects and remember it as the tool's look.
    private func styleEdited(_ style: AnnotationStyle) {
        if activeTool.descriptor.kind == .draw { ToolStyleSetting.save(style, for: activeTool.descriptor, settings: settings) }
        let selected = document.selectedAnnotations
        guard !selected.isEmpty else { return }

        var original = pendingStyleEdit?.original ?? selected
        if let pending = pendingStyleEdit {
            pending.work.cancel()
            original = pending.original
        }
        // Show the change at once; record it as one undo step when the user pauses.
        var changed = selected
        for index in changed.indices {
            var look = style
            // Properties this tool does not offer keep each object's own value.
            let offered = Set(optionsModel.properties)
            if !offered.contains(.stroke) { look.strokeColor = changed[index].style.strokeColor }
            if !offered.contains(.fill) { look.fillColor = changed[index].style.fillColor }
            if !offered.contains(.width) { look.lineWidth = changed[index].style.lineWidth }
            if !offered.contains(.opacity) { look.opacity = changed[index].style.opacity }
            if !offered.contains(.dash) { look.dash = changed[index].style.dash }
            if !offered.contains(.cornerRadius) { look.cornerRadius = changed[index].style.cornerRadius }
            changed[index].style = look
        }
        document.previewAnnotations(changed)

        let work = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pendingStyleEdit else { return }
            self.pendingStyleEdit = nil
            self.document.commitAnnotationEdit(from: pending.original, name: "Change Style")
        }
        pendingStyleEdit = (original, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func perform(_ action: ToolOptionsModel.ObjectAction) {
        let ids = document.selectedAnnotationIDs
        switch action {
        case .duplicate: document.duplicateAnnotations(ids: ids)
        case .delete: document.removeAnnotations(ids: ids)
        case .bringToFront: document.reorderAnnotations(ids: ids, .toFront)
        case .sendToBack: document.reorderAnnotations(ids: ids, .toBack)
        }
    }

    @discardableResult
    private func selectTool(key: String) -> Bool {
        guard let tool = tools.first(where: { $0.descriptor.key == key }) else { return false }
        selectTool(id: tool.descriptor.id)
        return true
    }

    private func cycleTool(backwards: Bool) {
        guard let index = tools.firstIndex(where: { $0 === activeTool }) else { return }
        let next = (index + (backwards ? tools.count - 1 : 1)) % tools.count
        selectTool(id: tools[next].descriptor.id)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didInitialFit, scrollView.contentSize.width > 50 {
            didInitialFit = true
            scrollView.zoomToFit()
        }
    }

    private func show(_ image: CGImage) {
        let size = CGSize(width: image.width, height: image.height)
        shownImage = image
        canvas.image = image
        if didInitialFit && size != lastPixelSize { scrollView.zoomToFit() }   // crop / resize / rotate: refit
        lastPixelSize = size
        updateStatus()
    }

    @objc private func zoomChanged() { updateStatus() }

    private func updateStatus() {
        guard let image = shownImage else { return }
        let selection = shownSelection
        var text = "\(image.width) × \(image.height) px     Zoom \(Int(scrollView.zoomPercent.rounded()))%"
        if let selection {
            let box = selection.bounds
            text += "     Selection \(Int(box.width)) × \(Int(box.height)) at \(Int(box.minX)), \(Int(box.minY))"
        }
        statusLabel.stringValue = text
    }
}
