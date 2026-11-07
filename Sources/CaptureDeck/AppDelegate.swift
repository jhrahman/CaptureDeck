import AppKit
import DesignSystem

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appearance = AppearanceController()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appearance.apply()
        statusItem = StatusItemController(appearance: appearance)
    }
}
