import AppKit
import CoreModels
import EditorEngine
import EditorUI
import Platform
import Settings

/// What happens with text captured straight from the screen.
enum TextCaptureAction: String, CaseIterable {
    case copy, copyAndShow, show

    var title: String {
        switch self {
        case .copy: "Copy it to the clipboard"
        case .copyAndShow: "Copy it, and show it for editing"
        case .show: "Only show it for editing"
        }
    }

    var copies: Bool { self != .show }
    var shows: Bool { self != .copy }
}

/// Reads the text (and any QR code or barcode) in a captured part of the screen, then copies or shows it.
@MainActor
final class TextCaptureDelivery {
    private let store: SettingsStore
    private var windows: [RecognizedTextWindow] = []
    var pasteboard = NSPasteboard.general

    init(store: SettingsStore) { self.store = store }

    nonisolated static func read(_ image: CGImage, options: TextReadingOptions, keepsLineBreaks: Bool) async -> String {
        await Task.detached(priority: .userInitiated) {
            let text = TextLayout.text(from: TextDetector.words(in: image, options: options), keepsLineBreaks: keepsLineBreaks)
            return CodeReader.combined(text: text, codes: CodeReader.codes(in: image))
        }.value
    }

    func deliver(_ image: CapturedImage) async {
        let language = store.string(TextReadingSetting.language)
        let options = TextReadingOptions(language: language.isEmpty ? nil : language, correctsSpelling: store.bool(TextReadingSetting.correctsSpelling))
        let text = await Self.read(image.cgImage, options: options, keepsLineBreaks: store.bool(TextReadingSetting.keepsLineBreaks))
        guard !text.isEmpty else {
            NoticeHUD.show("No text found there", symbol: "doc.text.magnifyingglass")        // the clipboard keeps what it had
            return
        }
        let action = TextCaptureAction(rawValue: store.string(SettingID.textCaptureAction)) ?? .copy
        if action.copies { copy(text) }
        if store.bool(SettingID.captureSound) { NSSound(named: NSSound.Name(store.string(SettingID.soundName)))?.play() }
        if action.shows {
            show(text)
        } else {
            NoticeHUD.show("Copied \(TextLayout.wordCount(text))", symbol: "doc.on.doc")
        }
    }

    private func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func show(_ text: String) {
        let window = RecognizedTextWindow(text: text, copy: { [weak self] edited in self?.copy(edited) }) { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
            ActivationPolicyManager.shared.release(closed)
        }
        windows.append(window)
        ActivationPolicyManager.shared.retain(window)
        window.show()
    }
}

/// A short message near the top of the screen that goes away by itself, for results that have no window.
@MainActor
enum NoticeHUD {
    private static var panel: NSPanel?
    private static var dismissal: Task<Void, Never>?

    static func show(_ message: String, symbol: String) {
        panel?.orderOut(nil)
        dismissal?.cancel()
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 62, height: 40)
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.appearance = NSAppearance(named: .darkAqua)
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        let icon = NSImageView(frame: NSRect(x: 16, y: 11, width: 18, height: 18))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = .white
        label.frame.origin = NSPoint(x: 44, y: (size.height - label.frame.height) / 2)
        background.addSubview(icon)
        background.addSubview(label)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? .zero
        let notice = NSPanel(contentRect: NSRect(x: area.midX - size.width / 2, y: area.maxY - size.height - 24, width: size.width, height: size.height),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        notice.level = .statusBar
        notice.isOpaque = false
        notice.backgroundColor = .clear
        notice.hasShadow = true
        notice.ignoresMouseEvents = true
        notice.isReleasedWhenClosed = false
        notice.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        notice.contentView = background
        notice.orderFrontRegardless()
        panel = notice
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        dismissal = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if !Task.isCancelled { notice.orderOut(nil) }
        }
    }
}
