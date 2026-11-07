import AppKit
import Combine
import DesignSystem
import EditorEngine
import Settings

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

        container.addSubview(scrollView)
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
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
            ToolContext(document: self?.document ?? EditorDocument(original: .placeholder, title: ""),
                        zoom: (self?.scrollView.magnification ?? 1) * (self?.view.window?.backingScaleFactor ?? 2))
        }
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
