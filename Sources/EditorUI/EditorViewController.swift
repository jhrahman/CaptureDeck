import AppKit
import Combine
import DesignSystem
import EditorEngine

/// The editor's content: the zoomable canvas and a status bar.
@MainActor
final class EditorViewController: NSViewController {
    let document: EditorDocument
    let scrollView = ZoomScrollView(frame: .zero)
    private let canvas = CanvasView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private var cancellables = Set<AnyCancellable>()
    private var didInitialFit = false
    private var lastPixelSize = CGSize.zero
    /// The image on screen. (`@Published` notifies before the property changes, so never re-read the document here.)
    private var shownImage: CGImage?

    init(document: EditorDocument) {
        self.document = document
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

        document.$workingImage
            .dropFirst()
            .sink { [weak self] image in self?.show(image.cgImage) }
            .store(in: &cancellables)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(zoomChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
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
        statusLabel.stringValue = "\(image.width) × \(image.height) px     Zoom \(Int(scrollView.zoomPercent.rounded()))%"
    }
}
