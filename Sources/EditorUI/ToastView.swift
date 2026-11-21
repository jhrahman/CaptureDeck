import AppKit

/// A small, transient confirmation ("Copied to clipboard") that floats near the bottom of a window and fades away.
@MainActor
final class ToastView: NSVisualEffectView {
    private static var current: ToastView?

    static func show(_ text: String, symbol: String = "checkmark.circle.fill", in window: NSWindow?, duration: TimeInterval = 1.6) {
        guard let host = window?.contentView else { return }
        current?.removeFromSuperview()
        let toast = ToastView(text: text, symbol: symbol)
        current = toast
        host.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -48),
        ])
        toast.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; toast.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak toast] in
            guard let toast else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; toast.animator().alphaValue = 0 },
                                                 completionHandler: { toast.removeFromSuperview(); if current === toast { current = nil } })
        }
    }

    private init(text: String, symbol: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .semibold).applying(.init(paletteColors: [.systemGreen]))) ?? NSImage())
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        setAccessibilityLabel(text)
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: text])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }      // never steals clicks
}
