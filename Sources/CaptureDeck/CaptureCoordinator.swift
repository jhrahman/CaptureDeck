import AppKit
import CaptureEngine
import CoreModels
import Platform

/// User-facing capture options. Backed by UserDefaults; a Settings screen will edit these later.
struct CaptureSettings {
    var autoCopyToClipboard = true
    var includeCursor = false

    static func load(from defaults: UserDefaults = .standard) -> CaptureSettings {
        var s = CaptureSettings()
        if defaults.object(forKey: "capture.autoCopy") != nil { s.autoCopyToClipboard = defaults.bool(forKey: "capture.autoCopy") }
        if defaults.object(forKey: "capture.includeCursor") != nil { s.includeCursor = defaults.bool(forKey: "capture.includeCursor") }
        return s
    }
}

/// Runs a capture mode end to end: permission check -> capture -> output steps.
/// Capture logic lives in CaptureEngine; this only orchestrates and talks to the user.
@MainActor
final class CaptureCoordinator {
    let modes: [any CaptureMode]
    private let grabber: any ScreenGrabber
    private let clipboard: ClipboardManager
    private var isCapturing = false

    init(modes: [any CaptureMode], grabber: any ScreenGrabber = ScreenCaptureKitGrabber(), clipboard: ClipboardManager = ClipboardManager()) {
        self.modes = modes
        self.grabber = grabber
        self.clipboard = clipboard
    }

    func run(modeID: String) {
        guard let mode = modes.first(where: { $0.id == modeID }) else { return }
        Task { await run(mode) }
    }

    private func run(_ mode: any CaptureMode) async {
        guard !isCapturing else { return }  // ignore hotkey repeats while a capture is in flight
        isCapturing = true
        defer { isCapturing = false }

        guard ensurePermission() else { return }

        let settings = CaptureSettings.load()
        do {
            let result = try await mode.run(CaptureContext(grabber: grabber, includeCursor: settings.includeCursor))
            try deliver(result, settings: settings)
        } catch CaptureError.cancelled {
            // User backed out; nothing to report.
        } catch CaptureError.permissionDenied {
            showPermissionAlert()
        } catch {
            showError(error)
        }
    }

    private func deliver(_ result: CaptureResult, settings: CaptureSettings) throws {
        switch result {
        case .image(let image):
            if settings.autoCopyToClipboard {
                try clipboard.copy(image)
            }
            NSSound(named: NSSound.Name("Tink"))?.play()
        }
    }

    // MARK: Permission

    private static let askedKey = "permission.screenRecording.asked"

    /// Returns true when capture may proceed. On the very first attempt this triggers the
    /// system prompt; afterwards it explains how to enable the permission.
    private func ensurePermission() -> Bool {
        if ScreenRecordingPermission.isGranted { return true }
        if !UserDefaults.standard.bool(forKey: Self.askedKey) {
            UserDefaults.standard.set(true, forKey: Self.askedKey)
            if ScreenRecordingPermission.request() { return true }
            return false  // system prompt is showing; the user retries after allowing
        }
        showPermissionAlert()
        return false
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = "CaptureDeck needs Screen Recording access to take screenshots. Nothing is recorded or uploaded; captures stay on your Mac.\n\nEnable CaptureDeck in System Settings > Privacy & Security > Screen Recording, then try again (you may need to reopen the app)."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenRecordingPermission.openSystemSettings()
        }
    }

    private func showError(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Capture failed"
        switch error {
        case CaptureError.noDisplayAvailable: alert.informativeText = "No display was available to capture."
        case CaptureError.captureFailed(let message): alert.informativeText = message
        default: alert.informativeText = error.localizedDescription
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
