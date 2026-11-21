import AppKit
import CaptureEngine
import CoreModels
import Platform
import Settings

/// The capture options in effect for one capture, read from the Settings store at that moment
/// (so changes made in Settings apply to the very next capture).
struct CaptureSettings {
    var autoCopyToClipboard: Bool
    var includeCursor: Bool
    var labelDisplays: Bool
    var delaySeconds: Int
    var openEditor: Bool
    var autoSave: Bool
    var saveFolder: URL
    var fileTemplate: String
    var format: ImageFileFormat
    var jpegQuality: Double
    var playSound: Bool
    var soundName: String

    @MainActor
    init(store: SettingsStore) {
        autoCopyToClipboard = store.bool(SettingID.autoCopy)
        includeCursor = store.bool(SettingID.includeCursor)
        labelDisplays = store.bool(SettingID.labelDisplays)
        delaySeconds = store.int(SettingID.delaySeconds)
        openEditor = store.bool(SettingID.openEditor)
        autoSave = store.bool(SettingID.autoSave)
        let folder = store.string(SettingID.saveFolder)
        saveFolder = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        let template = store.string(SettingID.fileTemplate)
        fileTemplate = template.isEmpty ? FilenameTemplate.defaultTemplate : template
        format = ImageFileFormat(rawValue: store.string(SettingID.format)) ?? .png
        jpegQuality = store.double(SettingID.jpegQuality)
        playSound = store.bool(SettingID.captureSound)
        soundName = store.string(SettingID.soundName)
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
    private let store: SettingsStore
    private var isCapturing = false
    /// Hooks around the actual capture (the panel hides itself so it is not in the screenshot).
    var beforeCapture: (@MainActor () async -> Void)?
    var afterCapture: (@MainActor () -> Void)?
    /// Called with each finished capture when "open in editor" is on.
    var openInEditor: (@MainActor (CapturedImage) -> Void)?

    init(modes: [any CaptureMode], lastCapture: LastCaptureStore, store: SettingsStore, grabber: any ScreenGrabber = ScreenCaptureKitGrabber(), clipboard: ClipboardManager = ClipboardManager()) {
        self.modes = modes
        self.lastCapture = lastCapture
        self.store = store
        self.grabber = grabber
        self.clipboard = clipboard
    }

    func run(modeID: String) {
        guard let mode = modes.first(where: { $0.id == modeID }) else { return }
        Task { await run(mode) }
    }

    private func run(_ mode: any CaptureMode) async {
        guard !isCapturing else {
            // Pressing the scrolling-capture shortcut again while it runs means "finish"; other repeats are ignored.
            if mode.id == "scrollingWindow" { NotificationCenter.default.post(name: .scrollingCaptureStopRequested, object: nil) }
            return
        }
        isCapturing = true
        defer { isCapturing = false }

        guard ensurePermission() else { return }
        if mode.wantsAccessibility { offerAccessibilityOnce() }

        let settings = CaptureSettings(store: store)
        if settings.delaySeconds > 0 { await CountdownHUD().run(seconds: settings.delaySeconds) }
        await beforeCapture?()
        defer { afterCapture?() }
        do {
            let result = try await mode.run(CaptureContext(grabber: grabber, includeCursor: settings.includeCursor, labelDisplays: settings.labelDisplays))
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
            // A clipboard problem must not lose the capture: keep going, and report it afterwards.
            var copyError: (any Error)?
            if settings.autoCopyToClipboard {
                do { try clipboard.copy(image) } catch { copyError = error }
            }
            if settings.autoSave { save(image, settings: settings) }
            if settings.openEditor { openInEditor?(image.withSource(nil)) }
            if settings.playSound { NSSound(named: NSSound.Name(settings.soundName))?.play() }
            if let copyError { throw copyError }
        }
    }

    /// Encoding a large capture takes a moment, so it runs off the main thread.
    private func save(_ image: CapturedImage, settings: CaptureSettings) {
        Task.detached {
            do {
                try FileSaver().save(image, to: settings.saveFolder, template: settings.fileTemplate, format: settings.format, jpegQuality: settings.jpegQuality)
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

    /// Returns true when capture may proceed. On the very first attempt this triggers the
    /// system prompt; afterwards it explains how to enable the permission.
    private func ensurePermission() -> Bool {
        if ScreenRecordingPermission.isGranted { return true }
        if !store.bool(SettingID.screenRecordingAsked) {
            store.set(true, for: SettingID.screenRecordingAsked)
            if ScreenRecordingPermission.request() { return true }
            return false  // system prompt is showing; the user retries after allowing
        }
        showPermissionAlert()
        return false
    }

    /// Accessibility is optional (window/object capture falls back to whole windows),
    /// so ask once and carry on without blocking the capture.
    private func offerAccessibilityOnce() {
        guard !AccessibilityPermission.isGranted, !store.bool(SettingID.accessibilityAsked) else { return }
        store.set(true, for: SettingID.accessibilityAsked)
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
