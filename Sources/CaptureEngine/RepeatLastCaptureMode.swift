import CoreModels
import Foundation

/// Remembers what the last successful capture grabbed, so it can be taken again.
public final class LastCaptureStore: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CaptureTarget?

    public init() {}

    public var target: CaptureTarget? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Captures the same screen, region or window as the last capture, live (not from a snapshot).
public struct RepeatLastCaptureMode: CaptureMode {
    public let id = "repeatLast"
    public let title = "Repeat Last Capture"
    public let defaultShortcut: KeyShortcut? = .digit(8, [.control, .shift])

    private let store: LastCaptureStore

    public init(store: LastCaptureStore) { self.store = store }

    public func run(_ context: CaptureContext) async throws -> CaptureResult {
        guard let target = store.target else {
            throw CaptureError.captureFailed("There is no previous capture to repeat yet.")
        }
        let image = try await context.grabber.capture(target, includeCursor: context.includeCursor)
        return .image(image.withSource(target))
    }
}
