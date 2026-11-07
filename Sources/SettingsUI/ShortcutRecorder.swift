import AppKit
import CoreModels
import Settings
import SwiftUI

/// Click, then press a key combination. Esc cancels, Delete clears.
struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: KeyShortcut?
    /// Called with the new shortcut, or nil when cleared.
    let onCommit: (KeyShortcut?) -> Void

    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField()
        field.onCommit = onCommit
        field.shortcut = shortcut
        return field
    }

    func updateNSView(_ field: RecorderField, context: Context) {
        field.onCommit = onCommit
        field.shortcut = shortcut
    }
}

@MainActor
final class RecorderField: NSView {
    var onCommit: ((KeyShortcut?) -> Void)?
    var shortcut: KeyShortcut? { didSet { needsDisplay = true } }
    private var isRecording = false {
        didSet {
            needsDisplay = true
            guard isRecording != oldValue else { return }
            NotificationCenter.default.post(name: .shortcutRecordingChanged, object: nil, userInfo: ["recording": isRecording])
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    override func mouseDown(with event: NSEvent) { startRecording() }

    private func startRecording() {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    // Accessibility: VoiceOver and UI scripting can press the control to start recording.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityValue() -> Any? { shortcut?.displayString ?? "Not set" }
    override func accessibilityHelp() -> String? { "Press, then type the new keyboard shortcut. Delete clears it, Escape cancels." }
    override func accessibilityPerformPress() -> Bool {
        startRecording()
        return true
    }

    // The window can close while recording; make sure hotkeys come back.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { isRecording = false }
        super.viewWillMove(toWindow: newWindow)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) { handle(event) }

    // Command combinations arrive here before keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        handle(event)
        return true
    }

    private func handle(_ event: NSEvent) {
        guard isRecording else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let code = UInt32(event.keyCode)

        if flags.isEmpty, code == 53 { stop(); return }                      // Esc: cancel
        if flags.isEmpty, code == 51 || code == 117 { onCommit?(nil); stop(); return }   // Delete: clear

        var modifiers: KeyShortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }

        let candidate = KeyShortcut(
            keyCode: code, modifiers: modifiers,
            keyLabel: KeyLabels.label(forKeyCode: code, typed: event.charactersIgnoringModifiers))
        guard ShortcutConflicts.isUsableAsGlobal(candidate) else { NSSound.beep(); return }   // needs ⌘, ⌥ or ⌃
        onCommit?(candidate)
        stop()
    }

    private func stop() {
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text: String
        let color: NSColor
        if isRecording { text = "Type shortcut…"; color = .secondaryLabelColor }
        else if let shortcut { text = shortcut.displayString; color = .labelColor }
        else { text = "Click to set"; color = .tertiaryLabelColor }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}
