import AppKit
import EditorEngine
import Platform
import Settings
import Testing
@testable import EditorUI

@MainActor
@Suite(.serialized)
struct CopyAndCloseTests {
    /// The controller holds its store weakly, so the caller keeps the store alive.
    private func makeController(closeAfterCopy: Bool) -> (EditorWindowController, EditorDocument, EditorStore) {
        let defaults = UserDefaults(suiteName: "CopyAndCloseTests.\(UUID().uuidString)")!
        let registry = SettingsRegistry([
            .init(id: "capture.closeEditorAfterCopy", section: .capture, title: "t", defaultValue: .bool(closeAfterCopy), control: .toggle),
            .init(id: "editor.askBeforeDiscard", section: .editor, title: "t", defaultValue: .bool(true), control: .toggle),
            .init(id: "editor.cropOnDrag", section: .editor, title: "t", defaultValue: .bool(true), control: .toggle),
            .init(id: "editor.selectAllOnOpen", section: .editor, title: "t", defaultValue: .bool(true), control: .toggle),
            .init(id: "editor.showSelectionSize", section: .editor, title: "t", defaultValue: .bool(true), control: .toggle),
            .init(id: "editor.defaultTool", section: .editor, title: "t", defaultValue: .string("rectSelect"), control: .hidden),
            .init(id: "capture.fileTemplate", section: .capture, title: "t", defaultValue: .string(""), control: .hidden),
            .init(id: "capture.format", section: .capture, title: "t", defaultValue: .string("png"), control: .hidden),
            .init(id: "capture.saveFolder", section: .capture, title: "t", defaultValue: .string(""), control: .hidden),
        ])
        let store = EditorStore(settings: SettingsStore(registry: registry, defaults: defaults))
        let doc = EditorDocument(original: UXSnapshotTests.sampleImage(), title: "t")
        return (EditorWindowController(editorDocument: doc, store: store), doc, store)
    }

    @Test func copyKeepsTheEditorOpenByDefault() {
        let (controller, _, store) = makeController(closeAfterCopy: false)
        controller.window?.orderFront(nil)
        controller.copyImage(nil)
        #expect(controller.window?.isVisible == true)
        controller.window?.close()
        withExtendedLifetime(store) {}
    }

    @Test func copyClosesTheEditorWhenTheSettingIsOnAndTheImageIsOnTheClipboard() {
        let (controller, doc, store) = makeController(closeAfterCopy: true)
        controller.window?.orderFront(nil)
        doc.apply(.rotate(quarterTurns: 1))                      // unsaved edits must not trigger the discard prompt
        NSPasteboard.general.clearContents()
        controller.copyImage(nil)
        #expect(controller.window?.isVisible == false)
        #expect(NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil))
        withExtendedLifetime(store) {}
    }
}
