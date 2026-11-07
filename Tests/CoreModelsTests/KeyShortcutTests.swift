import Foundation
import Testing
@testable import CoreModels

struct KeyShortcutTests {
    @Test func digitKeyCodesMatchAnsiLayout() {
        // kVK_ANSI_0...9
        let expected: [UInt32] = [0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]
        for n in 0...9 {
            #expect(KeyShortcut.digit(n, []).keyCode == expected[n])
        }
    }

    @Test func displayStringOrdersModifiers() {
        #expect(KeyShortcut.digit(1, [.control, .shift]).displayString == "⌃⇧1")
        #expect(KeyShortcut.digit(2, [.command, .option, .control, .shift]).displayString == "⌃⌥⇧⌘2")
    }

    @Test func codableRoundTrip() throws {
        let original = KeyShortcut.digit(7, [.control, .shift])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(KeyShortcut.self, from: data) == original)
    }
}
