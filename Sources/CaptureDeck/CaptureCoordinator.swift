import AppKit
import CaptureEngine
import CoreModels
import Platform

/// User-facing capture options. Backed by UserDefaults; a Settings screen will edit these later.
struct CaptureSettings {
    var autoCopyToClipboard = true
    var includeCursor = false
    var delaySeconds = 0
    var autoSave = false
    var saveFolder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("CaptureDeck", isDirectory: true)
    var fileTemplate = FilenameTemplate.defaultTemplate
    var format = ImageFileFormat.png

    static func load(from defaults: UserDefaults = .standard) -> CaptureSettings {
        var s = CaptureSettings()
        func bool(_ key: String) -> Bool? { defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key) }
        if let v = bool("capture.autoCopy") { s.autoCopyToClipboard = v }
        if let v = bool("capture.includeCursor") { s.includeCursor = v }
        if let v = bool("capture.autoSave") { s.autoSave = v }
        if defaults.object(forKey: "capture.delaySeconds") != nil {
            s.delaySeconds = min(max(defaults.integer(forKey: "capture.delaySeconds"), 0), 30)
        }
        if let path = defaults.string(forKey: "capture.saveFolder"), !path.isEmpty {
            s.saveFolder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let t = defaults.string(forKey: "capture.fileTemplate"), !t.isEmpty { s.fileTemplate = t }
        if let f = defaults.string(forKey: "capture.format").flatMap(ImageFileFormat.init(rawValue:)) { s.format = f }
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
    private let lastCapture: LastCaptureStore
    private var isCapturing = false

    init(modes: [any CaptureMode], lastCapture: LastCaptureStore, grabber: any ScreenGrabber = ScreenCaptureKitGrabber(), clipboard: ClipboardManager = ClipboardManager()) {
        self.modes = modes
        self.lastCapture = lastCapture
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
        if mode.wantsAccessibility { offerAccessibilityOnce() }

        let settings = CaptureSettings.load()
        if settings.delaySeconds > 0 { await CountdownHUD().run(seconds: settings.delaySeconds) }
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
            if let source = image.source { lastCapture.target = source }
            if settings.autoCopyToClipboard {
                try clipboard.copy(image)
            }
            if settings.autoSave { save(image, settings: settings) }
            NSSound(named: NSSound.Name("Tink"))?.play()
        }
    }

    /// Encoding a large capture takes a moment, so it runs off the main thread.
    private func save(_ image: CapturedImage, settings: CaptureSettings) {
        Task.detached {
            do {
                try FileSaver().save(image, to: settings.saveFolder, template: settings.fileTemplate, format: settings.format)
            } catch {
                await self.showSaveError(error, folder: settings.saveFolder)
            }
        }
    }

    private func showSaveError(_ error: any Error, folder: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not save the screenshot"
        alert.informativeText = "The image is still on the clipboard. Check that CaptureDeck can write to \(folder.path)."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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

    private static let axAskedKey = "permission.accessibility.asked"

    /// Accessibility is optional (window/object capture falls back to whole windows),
    /// so ask once and carry on without blocking the capture.
    private func offerAccessibilityOnce() {
        guard !AccessibilityPermission.isGranted, !UserDefaults.standard.bool(forKey: Self.axAskedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.axAskedKey)
        AccessibilityPermission.requestPrompt()
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
