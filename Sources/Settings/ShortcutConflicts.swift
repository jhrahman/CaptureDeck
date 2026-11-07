import CoreModels
import Foundation

/// A shortcut currently assigned to one of the app's actions.
public struct ShortcutAssignment: Sendable, Equatable {
    public let id: String
    public let title: String
    public let shortcut: KeyShortcut

    public init(id: String, title: String, shortcut: KeyShortcut) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
    }
}

public enum ShortcutConflict: Equatable, Sendable {
    /// Another CaptureDeck action already uses it. This blocks the change.
    case sameApp(actionTitle: String)
    /// macOS or a common system feature uses it. Allowed, with a warning.
    case system(description: String)

    public var message: String {
        switch self {
        case .sameApp(let title): "Already used by “\(title)”."
        case .system(let what): "May conflict with \(what)."
        }
    }

    public var blocksChange: Bool {
        if case .sameApp = self { return true }
        return false
    }
}

public enum ShortcutConflicts {
    /// Virtual key codes (kVK_*) of the keys involved.
    private static let space: UInt32 = 49, tab: UInt32 = 48, escape: UInt32 = 53
    private static let digit3: UInt32 = 0x14, digit4: UInt32 = 0x15, digit5: UInt32 = 0x17

    static let systemShortcuts: [(KeyShortcut, String)] = [
        (KeyShortcut(keyCode: space, modifiers: [.command], keyLabel: "Space"), "Spotlight"),
        (KeyShortcut(keyCode: space, modifiers: [.command, .option], keyLabel: "Space"), "Finder search"),
        (KeyShortcut(keyCode: space, modifiers: [.control], keyLabel: "Space"), "switching input sources"),
        (KeyShortcut(keyCode: tab, modifiers: [.command], keyLabel: "Tab"), "the app switcher"),
        (KeyShortcut(keyCode: escape, modifiers: [.command, .option], keyLabel: "Esc"), "Force Quit"),
        (KeyShortcut(keyCode: digit3, modifiers: [.command, .shift], keyLabel: "3"), "the macOS screenshot shortcut"),
        (KeyShortcut(keyCode: digit4, modifiers: [.command, .shift], keyLabel: "4"), "the macOS screenshot shortcut"),
        (KeyShortcut(keyCode: digit5, modifiers: [.command, .shift], keyLabel: "5"), "the macOS screenshot toolbar"),
    ]

    /// `id` is the action being changed (it is ignored when looking for duplicates).
    public static func check(_ shortcut: KeyShortcut, for id: String, among assignments: [ShortcutAssignment]) -> ShortcutConflict? {
        if let other = assignments.first(where: { $0.id != id && $0.shortcut.keyCode == shortcut.keyCode && $0.shortcut.modifiers == shortcut.modifiers }) {
            return .sameApp(actionTitle: other.title)
        }
        if let system = systemShortcuts.first(where: { $0.0.keyCode == shortcut.keyCode && $0.0.modifiers == shortcut.modifiers }) {
            return .system(description: system.1)
        }
        return nil
    }

    /// A global shortcut needs at least one of Command / Option / Control, or it would swallow normal typing.
    public static func isUsableAsGlobal(_ shortcut: KeyShortcut) -> Bool {
        !shortcut.modifiers.isDisjoint(with: [.command, .option, .control])
    }
}

/// Names for keys that have no printable character.
public enum KeyLabels {
    private static let special: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 71: "Clear", 76: "⌤",
        115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    ]

    /// The label for a key; `typed` is what the key produces without modifiers (e.g. "a").
    public static func label(forKeyCode keyCode: UInt32, typed: String?) -> String {
        if let name = special[keyCode] { return name }
        let text = (typed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Key \(keyCode)" : text.uppercased()
    }
}

public extension Notification.Name {
    /// Posted by the shortcut recorder when it starts or stops listening (`userInfo["recording"]` is a Bool).
    /// Global hotkeys must pause while recording, or pressing a combination that is already a hotkey
    /// would trigger the action instead of being recorded.
    static let shortcutRecordingChanged = Notification.Name("app.capturedeck.shortcutRecordingChanged")
}
