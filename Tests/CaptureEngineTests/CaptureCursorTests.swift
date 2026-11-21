import AppKit
import Testing
@testable import CaptureEngine

@MainActor
struct CaptureCursorTests {
    @Test func everyCaptureKindHasItsOwnBadgedCursor() {
        let badges: [CaptureCursors.Badge] = [.region, .fixedSize, .freehand, .window]
        let cursors = badges.map { CaptureCursors.cursor(for: $0) }
        #expect(Set(cursors.map { ObjectIdentifier($0) }).count == badges.count)
        for cursor in cursors { #expect(cursor.image.size.width > 0 && cursor.hotSpot.x > 0) }
        #expect(CaptureCursors.cursor(for: .region) === CaptureCursors.cursor(for: .region))   // cached
    }
}
