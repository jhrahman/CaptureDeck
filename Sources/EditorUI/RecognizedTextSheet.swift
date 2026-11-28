import AppKit
import EditorEngine
import SwiftUI
import UniformTypeIdentifiers

/// The text read from a picture, ready to correct, copy or save.
struct RecognizedTextSheet: View {
    @State var text: String
    let copy: (String) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Text in the Picture").font(.headline)
                Spacer()
                Text("\(TextLayout.wordCount(text))  ·  \(text.count) characters").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.18)))
                .accessibilityLabel("Recognized text")
            Text("Check names, numbers and codes: reading text from pictures can make mistakes.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Save as Text File…", action: save)
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                Button("Copy Text") { copy(text); close() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command).help("Copy and close (⌘↩)")
            }
        }
        .padding(18)
        .frame(width: 580, height: 440)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Recognized Text.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(text.utf8).write(to: url, options: .atomic) } catch { NSAlert(error: error).runModal() }
    }
}

/// The same text view in a window of its own, for text captured straight from the screen.
@MainActor
public final class RecognizedTextWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onClosed: (RecognizedTextWindow) -> Void

    public init(text: String, copy: @escaping (String) -> Void, onClosed: @escaping (RecognizedTextWindow) -> Void) {
        self.onClosed = onClosed
        super.init()
        let window = TextSheetWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Captured Text"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RecognizedTextSheet(
            text: text, copy: copy, close: { [weak window] in window?.close() }))
        window.delegate = self
        self.window = window
    }

    public func show() {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        window = nil
        onClosed(self)
    }
}

/// A sheet whose text box answers the usual editing shortcuts. The editor's menu bar is made for pictures (⌘C copies the
/// image there), so a window gets the keys first and applies them to its text.
final class TextSheetWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if let text = firstResponder as? NSText, flags.contains(.command), flags.isDisjoint(with: [.control, .option]) {
            switch (event.charactersIgnoringModifiers?.lowercased(), flags.contains(.shift)) {
            case ("a", false): text.selectAll(nil); return true
            case ("c", false): text.copy(nil); return true
            case ("v", false): text.paste(nil); return true
            case ("x", false): text.cut(nil); return true
            case ("z", false): text.undoManager?.undo(); return true
            case ("z", true): text.undoManager?.redo(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
