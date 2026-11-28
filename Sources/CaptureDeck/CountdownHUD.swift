import AppKit

/// A small "3, 2, 1" overlay so the user can open a menu or arrange the screen before the capture starts.
/// It is closed (and the screen allowed to redraw) before the capture, so it never appears in the image.
@MainActor
final class CountdownHUD {
    private(set) var wasCancelled = false
    private var waiting: Task<Void, Never>?

    /// Ends the countdown early; the caller then does not capture.
    func cancel() {
        wasCancelled = true
        waiting?.cancel()
    }

    /// With a `hint`, the countdown can be clicked to cancel it, and the hint says so.
    func run(seconds: Int, hint: String? = nil) async {
        guard seconds > 0, !wasCancelled else { return }

        let size = CGSize(width: hint == nil ? 140 : 210, height: hint == nil ? 140 : 160)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let center = CGPoint(x: screen?.frame.midX ?? 400, y: screen?.frame.midY ?? 400)

        let panel = NSPanel(
            contentRect: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = hint == nil
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 28
        background.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "\(seconds)")
        label.font = .systemFont(ofSize: 72, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = CGRect(x: 0, y: (size.height - 88) / 2 + (hint == nil ? 0 : 10), width: size.width, height: 88)
        background.addSubview(label)
        if let hint {
            let note = NSTextField(labelWithString: hint)
            note.font = .systemFont(ofSize: 11.5, weight: .medium)
            note.textColor = .secondaryLabelColor
            note.alignment = .center
            note.frame = CGRect(x: 0, y: 18, width: size.width, height: 18)
            background.addSubview(note)
            let button = ClickAnywhere(frame: background.bounds) { [weak self] in self?.cancel() }
            background.addSubview(button)
        }
        panel.contentView = background
        panel.orderFrontRegardless()

        let task = Task { @MainActor in
            for remaining in stride(from: seconds, through: 1, by: -1) {
                if Task.isCancelled { return }
                label.stringValue = "\(remaining)"
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        waiting = task
        await task.value
        panel.orderOut(nil)
        // Give the window server a moment to remove the HUD before pixels are grabbed.
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    private final class ClickAnywhere: NSView {
        private let action: () -> Void
        init(frame: NSRect, action: @escaping () -> Void) {
            self.action = action
            super.init(frame: frame)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { action() }
    }
}
