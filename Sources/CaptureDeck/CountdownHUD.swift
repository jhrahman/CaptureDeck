import AppKit

/// A small "3, 2, 1" overlay so the user can open a menu or arrange the screen before the capture starts.
/// It is closed (and the screen allowed to redraw) before the capture, so it never appears in the image.
@MainActor
final class CountdownHUD {
    func run(seconds: Int) async {
        guard seconds > 0 else { return }

        let size = CGSize(width: 140, height: 140)
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
        panel.ignoresMouseEvents = true
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
        label.frame = CGRect(x: 0, y: (size.height - 88) / 2, width: size.width, height: 88)
        background.addSubview(label)
        panel.contentView = background
        panel.orderFrontRegardless()

        for remaining in stride(from: seconds, through: 1, by: -1) {
            label.stringValue = "\(remaining)"
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        panel.orderOut(nil)
        // Give the window server a moment to remove the HUD before pixels are grabbed.
        try? await Task.sleep(nanoseconds: 150_000_000)
    }
}
