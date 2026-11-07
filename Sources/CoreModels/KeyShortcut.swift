/// A keyboard shortcut as data (virtual key code + modifiers), independent of Carbon/AppKit.
public struct KeyShortcut: Sendable, Hashable, Codable {
    public struct Modifiers: OptionSet, Sendable, Hashable, Codable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    /// macOS virtual key code (kVK_*).
    public let keyCode: UInt32
    public let modifiers: Modifiers
    /// Character shown in menus, e.g. "1".
    public let keyLabel: String

    public init(keyCode: UInt32, modifiers: Modifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    // ANSI digit row virtual key codes, indexed by digit.
    private static let digitKeyCodes: [UInt32] = [0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]

    /// Shortcut for a digit key 0...9.
    public static func digit(_ n: Int, _ modifiers: Modifiers) -> KeyShortcut {
        precondition((0...9).contains(n), "digit must be 0...9")
        return KeyShortcut(keyCode: digitKeyCodes[n], modifiers: modifiers, keyLabel: String(n))
    }

    /// Human-readable form such as "⌃⇧1".
    public var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + keyLabel
    }
}
