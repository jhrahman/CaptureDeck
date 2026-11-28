import AVFoundation
import AppKit
import ApplicationServices
import CaptureEngine
import Combine
import CoreModels
import Platform
import RecordingEngine
import RecordingUI
import Settings

/// What a recording captures, as the user chooses it.
enum RecordingSourceKind: String, CaseIterable {
    case display, region, window

    var title: String {
        switch self {
        case .display: "Full screen (the one with the pointer)"
        case .region: "A region I drag"
        case .window: "A window I click"
        }
    }

    var menuTitle: String {
        switch self {
        case .display: "Record Full Screen"
        case .region: "Record Region"
        case .window: "Record Window"
        }
    }
}

/// The recording settings in effect for one recording, read when it starts.
struct RecordingSettings {
    var configuration = RecordingConfiguration()
    var countdown: Int
    var showControls: Bool
    var showOutline: Bool
    var highlights: HighlightOptions
    var controlsStyle: ControlsStyle
    var menuBarTime: Bool
    var exactTrim: Bool
    var showReview: Bool
    var format: ExportFormat
    var folder: URL
    var template: String
    var gif: GIFOptions
    var mixAudio: Bool
    var maximumSeconds: Double

    @MainActor
    init(store: SettingsStore) {
        configuration.frameRate = Int(store.string(SettingID.recFrameRate)).flatMap(FrameRate.init(rawValue:)) ?? .fps60
        configuration.codec = VideoCodec(rawValue: store.string(SettingID.recCodec)) ?? .hevc
        configuration.quality = VideoQuality(rawValue: store.string(SettingID.recQuality)) ?? .high
        configuration.sharpColor = store.bool(SettingID.recSharpColor)
        configuration.scale = ResolutionScale(rawValue: store.string(SettingID.recResolution)) ?? .native
        configuration.timing = FrameTiming(rawValue: store.string(SettingID.recTiming)) ?? .variable
        configuration.showsCursor = store.bool(SettingID.recCursor)
        configuration.capturesSystemAudio = store.bool(SettingID.recSystemAudio)
        configuration.excludesOwnAudio = store.bool(SettingID.recExcludeOwnAudio)
        configuration.capturesMicrophone = store.bool(SettingID.recMicrophone)
        let device = store.string(SettingID.recMicrophoneDevice)
        configuration.microphoneID = device.isEmpty ? nil : device
        configuration.audioBitrate = Int(store.string(SettingID.recAudioBitrate)) ?? 160_000
        countdown = store.int(SettingID.recCountdown)
        showControls = store.bool(SettingID.recControls)
        showOutline = store.bool(SettingID.recOutline)
        highlights = Self.highlights(store)
        controlsStyle = ControlsStyle(
            size: ControlsSize(rawValue: store.string(SettingID.recControlsSize)) ?? .compact,
            position: ControlsPosition(rawValue: store.string(SettingID.recControlsPosition)) ?? .bottomLeft,
            opacity: store.double(SettingID.recControlsOpacity), showsFileSize: store.bool(SettingID.recControlsFileSize),
            confirmsDiscard: store.bool(SettingID.recConfirmDiscard))
        menuBarTime = store.bool(SettingID.recMenuBarTime)
        exactTrim = store.bool(SettingID.recExactTrim)
        showReview = store.bool(SettingID.recReview)
        format = ExportFormat(rawValue: store.string(SettingID.recFormat)) ?? .mp4
        folder = URL(fileURLWithPath: (store.string(SettingID.recFolder) as NSString).expandingTildeInPath, isDirectory: true)
        let name = store.string(SettingID.recTemplate)
        template = name.isEmpty ? AppSettings.defaultRecordingTemplate : name
        gif = GIFOptions(frameRate: Int(store.string(SettingID.recGIFRate)) ?? 12, maximumWidth: Int(store.string(SettingID.recGIFWidth)) ?? 960)
        mixAudio = store.bool(SettingID.recMixAudio)
        maximumSeconds = (Double(store.string(SettingID.recMaxMinutes)) ?? 0) * 60
    }

    @MainActor
    private static func highlights(_ store: SettingsStore) -> HighlightOptions {
        func color(_ id: String, _ fallback: NSColor) -> NSColor {
            RGBAColor(hex: store.string(id)).map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) } ?? fallback
        }
        func points(_ id: String, _ fallback: CGFloat) -> CGFloat { Double(store.string(id)).map { CGFloat($0) } ?? fallback }
        let halo = store.bool(SettingID.recHalo)
            ? PointerHalo(color: color(SettingID.recHaloColor, .systemYellow), diameter: points(SettingID.recHaloSize, 44),
                          style: HaloStyle(rawValue: store.string(SettingID.recHaloStyle)) ?? .filled)
            : nil
        let clicks = store.bool(SettingID.recClicks)
            ? ClickEffect(leftColor: color(SettingID.recClickColor, .systemYellow), rightColor: color(SettingID.recRightClickColor, .systemBlue),
                          diameter: points(SettingID.recClickSize, 48))
            : nil
        return HighlightOptions(halo: halo, clicks: clicks, keystrokes: KeystrokeMode(rawValue: store.string(SettingID.recKeystrokes)) ?? .off)
    }
}

/// Runs a recording from "choose what to record" to the saved file. Capture and encoding live in RecordingEngine and the
/// windows in RecordingUI; this connects them and talks to the user.
@MainActor
final class RecordingCoordinator {
    enum State { case idle, starting, recording, paused, finishing }

    private(set) var state = State.idle { didSet { if state != oldValue { onStateChange?() } } }
    var onStateChange: (() -> Void)?
    var beforeRecording: (@MainActor () async -> Void)?
    var afterRecording: (@MainActor () -> Void)?
    /// True while a screenshot is being taken, when a recording must not start its own selection overlay.
    var isScreenshotRunning: () -> Bool = { false }
    /// The elapsed time to show beside the menu bar icon, or nil for none.
    var onMenuBarTime: ((String?) -> Void)?
    /// Makes Esc call the handler (nil: stop doing that). Used only during the countdown.
    var setEscapeHandler: (((@MainActor () -> Void)?) -> Void)?
    var hasLastRegion: Bool { lastRegion != nil }
    var isActive: Bool { state != .idle }

    private let store: SettingsStore
    private let selector: any RegionSelecting
    private let grabber: any ScreenGrabber = ScreenCaptureKitGrabber()

    private var recorder: ScreenRecorder?
    private var settings: RecordingSettings?
    private var master: URL?
    private var controls: RecordingControlsModel?
    private var controlsPanel: RecordingControlsPanel?
    private var overlay: InputHighlightOverlay?
    private var outline: RegionOutline?
    private var ticker: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var elapsedBefore = 0.0
    /// Why CaptureDeck stopped a recording by itself; shown with the result, so saving is never held up by a dialog.
    private var stopReason: String?
    private var runningSince: Date?
    private var reviews: [ReviewWindowController] = []
    private var source: RecordingSource?
    private var countdown: CountdownHUD?
    private var cancelRequested = false
    private var settingsChanges: AnyCancellable?

    private static let minimumFreeSpaceToStart: Int64 = 1_000_000_000
    private static let minimumFreeSpace: Int64 = 400_000_000

    /// Where recordings are written until they are saved or discarded. Anything left here was never saved.
    static var workFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("CaptureDeck/Recordings", isDirectory: true)
    }

    init(store: SettingsStore, selector: any RegionSelecting) {
        self.store = store
        self.selector = selector
        // Looks that can change in the middle of a recording follow the Settings window as soon as Apply is pressed.
        settingsChanges = store.changes.filter { $0.hasPrefix("recording.") && $0 != SettingID.recControlsOrigin && $0 != SettingID.recLastRegion }
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)        // one Apply can change many settings at once
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.applyLiveSettings() } }
    }

    // MARK: Commands

    /// What a new recording captures: chosen now, or the same as before.
    private enum Request {
        case choose(RecordingSourceKind)
        case again(RecordingSource)
    }

    /// The Record shortcut: start with the default source, cancel a countdown, or stop.
    func toggle() {
        switch state {
        case .idle: start(RecordingSourceKind(rawValue: store.string(SettingID.recSource)) ?? .display)
        case .starting: cancelStart()
        case .recording, .paused: stop()
        case .finishing: break
        }
    }

    func start(_ kind: RecordingSourceKind) { start(.choose(kind)) }

    /// Records the same region as last time, without dragging it again.
    func startLastRegion() {
        guard let lastRegion else { return }
        start(.again(lastRegion))
    }

    private func start(_ request: Request) {
        guard state == .idle, !isScreenshotRunning() else { return }
        state = .starting
        cancelRequested = false
        Task { await begin(request) }
    }

    /// Calls off a recording that has not started yet (during the countdown).
    func cancelStart() {
        guard state == .starting else { return }
        cancelRequested = true
        countdown?.cancel()
    }

    /// Throws away what has been recorded and starts again on the same screen, region or window.
    func restart() {
        guard state == .recording || state == .paused, let recorder, let source else { return }
        state = .finishing
        Task {
            await recorder.discard()
            tearDown()
            start(.again(source))
        }
    }

    private var lastRegion: RecordingSource? {
        let parts = store.string(SettingID.recLastRegion).split(separator: ",").compactMap { Double($0) }
        guard parts.count == 5, NSScreen.screens.contains(where: { Self.displayID($0) == UInt32(parts[0]) }) else { return nil }
        return .region(CGRect(x: parts[1], y: parts[2], width: parts[3], height: parts[4]), display: UInt32(parts[0]))
    }

    func togglePause() {
        guard let recorder else { return }
        if state == .recording {
            recorder.pause()
            elapsedBefore = elapsed
            runningSince = nil
            state = .paused
        } else if state == .paused {
            recorder.resume()
            runningSince = Date()
            state = .recording
        }
        controls?.isPaused = state == .paused
    }

    func stop() {
        guard state == .recording || state == .paused else { return }
        Task { await finish() }
    }

    func discard() {
        guard state == .recording || state == .paused, let recorder else { return }
        state = .finishing
        Task {
            await recorder.discard()
            tearDown()
        }
    }

    private var elapsed: Double { elapsedBefore + (runningSince.map { Date().timeIntervalSince($0) } ?? 0) }

    // MARK: Starting

    private func begin(_ request: Request) async {
        let settings = RecordingSettings(store: store)
        guard checkPermission() else { state = .idle; return }
        if settings.configuration.capturesMicrophone {
            // Ask now, so the system's question is not in the video.
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            if !allowed { show(RecordingError.microphoneDenied); state = .idle; return }
        }
        do {
            try FileManager.default.createDirectory(at: Self.workFolder, withIntermediateDirectories: true)
        } catch {
            show(error); state = .idle; return
        }
        if Self.freeSpace() < Self.minimumFreeSpaceToStart {
            show(RecordingError.writer("There is less than 1 GB of free disk space.")); state = .idle; return
        }
        await beforeRecording?()
        do {
            let source: RecordingSource
            switch request {
            case .choose(let kind): source = try await choose(kind)
            case .again(let previous): source = previous
            }
            if cancelRequested { throw CaptureError.cancelled }
            if settings.countdown > 0 {
                let hud = CountdownHUD()
                countdown = hud
                setEscapeHandler? { [weak self] in self?.cancelStart() }
                await hud.run(seconds: settings.countdown, hint: "Click or press Esc to cancel")
                setEscapeHandler?(nil)
                countdown = nil
                if cancelRequested || hud.wasCancelled { throw CaptureError.cancelled }
            }
            try await startRecorder(source, settings: settings)
        } catch CaptureError.cancelled {
            tearDown()
        } catch CaptureError.permissionDenied {
            tearDown()
            showPermissionAlert()
        } catch {
            tearDown()
            show(error)
        }
    }

    private func choose(_ kind: RecordingSourceKind) async throws -> RecordingSource {
        switch kind {
        case .display:
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            guard let id = screen.flatMap(Self.displayID) else { throw RecordingError.sourceUnavailable }
            return .display(id)
        case .region:
            let snapshots = try await SelectionSnapshots.take(grabber: grabber)
            switch try await selector.selectRegion(on: snapshots, kind: .drag) {
            case .rect(let rect, let id): return .region(rect, display: id)
            case .display(let id): return .display(id)
            default: throw CaptureError.cancelled
            }
        case .window:
            let snapshots = try await SelectionSnapshots.take(grabber: grabber)
            let finder = WindowOnlyFinder(hint: "Click a window to record it   Esc cancel")
            guard case .window(let id) = try await selector.pickTarget(on: snapshots, finder: finder) else { throw CaptureError.cancelled }
            if let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
               let pid = info[kCGWindowOwnerPID as String] as? Int32 {
                NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            return .window(id)
        }
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The recorded rectangle in Cocoa screen coordinates.
    private static func area(of source: RecordingSource) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func cocoa(_ global: CGRect) -> NSRect { NSRect(x: global.minX, y: primaryHeight - global.maxY, width: global.width, height: global.height) }
        switch source {
        case .display(let id): return cocoa(CGDisplayBounds(id))
        case .region(let rect, let id):
            let display = CGDisplayBounds(id)
            return cocoa(rect.offsetBy(dx: display.minX, dy: display.minY))
        case .window(let id): return cocoa(WindowLocator.bounds(of: id) ?? .zero)
        }
    }

    private func startRecorder(_ source: RecordingSource, settings: RecordingSettings) async throws {
        let area = Self.area(of: source)
        let screen = NSScreen.screens.first { $0.frame.intersects(area) } ?? NSScreen.main
        var excluded: [CGWindowID] = []
        var overlays: [CGWindowID] = []

        let model = RecordingControlsModel()
        model.hasMicrophone = settings.configuration.capturesMicrophone
        model.onPauseResume = { [weak self] in self?.togglePause() }
        model.onStop = { [weak self] in self?.stop() }
        model.onDiscard = { [weak self] in self?.discard() }
        model.onRestart = { [weak self] in self?.restart() }
        model.style = settings.controlsStyle
        model.onToggleMicrophone = { [weak self, weak model] in
            guard let recorder = self?.recorder else { return }
            recorder.isMicrophoneMuted.toggle()
            model?.isMicrophoneMuted = recorder.isMicrophoneMuted
        }
        controls = model
        if settings.showControls {
            let panel = RecordingControlsPanel(model: model)
            panel.onDragged = { [weak self] origin in self?.store.set("\(Int(origin.x)),\(Int(origin.y))", for: SettingID.recControlsOrigin) }
            panel.show(near: area, dock: Self.dockFrame(), customOrigin: draggedOrigin)
            panel.apply(settings.controlsStyle)
            controlsPanel = panel
            excluded.append(panel.windowID)
        }
        if settings.showOutline, case .region = source {
            let line = RegionOutline(around: area)
            outline = line
            excluded.append(line.windowID)
        }
        if !settings.highlights.isEmpty, let screen {
            if settings.highlights.keystrokes != .off, !AccessibilityPermission.isGranted { AccessibilityPermission.requestPrompt() }
            let highlight = makeOverlay(on: screen, for: source, options: settings.highlights)
            overlay = highlight
            overlays.append(highlight.windowID)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)          // let the window server learn about the new windows

        let name = FilenameTemplate.suggestedName(template: settings.template) { candidate in
            ExportFormat.allCases.contains { FileManager.default.fileExists(atPath: settings.folder.appendingPathComponent("\(candidate).\($0.fileExtension)").path) }
        }
        var url = Self.workFolder.appendingPathComponent("\(name).mov")
        if FileManager.default.fileExists(atPath: url.path) { url = Self.workFolder.appendingPathComponent("\(name) \(UUID().uuidString.prefix(4)).mov") }

        let recorder = ScreenRecorder(source: source, configuration: settings.configuration)
        recorder.onInterrupted = { [weak self] message in
            Task { @MainActor in
                self?.stopReason = "stopped by macOS: \(message)"
                self?.stop()                                                          // keep what was recorded
            }
        }
        try await recorder.start(writingTo: url, excludedWindows: excluded, overlayWindows: overlays)
        self.recorder = recorder
        self.settings = settings
        self.source = source
        if case .region(let rect, let id) = source {
            store.set("\(id),\(rect.minX),\(rect.minY),\(rect.width),\(rect.height)", for: SettingID.recLastRegion)
        }
        master = url
        overlay?.start()
        elapsedBefore = 0
        stopReason = nil
        runningSince = Date()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                                                         reason: "Recording the screen")
        state = .recording
        watch()
    }

    private func makeOverlay(on screen: NSScreen, for source: RecordingSource, options: HighlightOptions) -> InputHighlightOverlay {
        InputHighlightOverlay(screen: screen, options: options, area: { Self.area(of: source) },
                              ignoring: { [weak self] in self?.controlsPanel?.frame ?? .zero })
    }

    private var draggedOrigin: NSPoint? {
        let parts = store.string(SettingID.recControlsOrigin).split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? NSPoint(x: parts[0], y: parts[1]) : nil
    }

    /// The Dock's frame in Cocoa coordinates. Only the Accessibility API reports it; nil without that permission.
    private static func dockFrame() -> NSRect? {
        guard AccessibilityPermission.isGranted,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
        }
        guard let children = value(app, "AXChildren") as? [AXUIElement],
              let list = children.first(where: { value($0, "AXRole") as? String == "AXList" }),
              let position = value(list, "AXPosition"), let size = value(list, "AXSize") else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: point.x, y: primaryHeight - point.y - extent.height, width: extent.width, height: extent.height)
    }

    private func applyLiveSettings() {
        guard state == .recording || state == .paused, var current = settings, let source else { return }
        let new = RecordingSettings(store: store)
        // Only looks change mid-recording: how the video is encoded stays as it was started.
        current.controlsStyle = new.controlsStyle
        current.menuBarTime = new.menuBarTime
        current.highlights = new.highlights
        settings = current
        controlsPanel?.apply(new.controlsStyle)
        onMenuBarTime?(new.menuBarTime ? RecordingControlsModel.clock(elapsed) : nil)      // at once, not at the next tick
        if let overlay {
            overlay.update(new.highlights)
        } else if !new.highlights.isEmpty {
            // A window recording shows only windows chosen when it started, so a new overlay would not be in the video.
            if case .window = source { return }
            let area = Self.area(of: source)
            guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(area) }) else { return }
            let highlight = makeOverlay(on: screen, for: source, options: new.highlights)
            overlay = highlight
            highlight.start()
        }
    }

    /// Keeps the controls up to date and stops safely if the disk fills up, writing fails or the time limit is reached.
    private func watch() {
        ticker = Task { [weak self] in
            var turn = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, let recorder = self.recorder, self.state == .recording || self.state == .paused else { continue }
                turn += 1
                self.controls?.microphoneLevel = recorder.microphoneLevel
                guard turn % 3 == 0 else { continue }
                self.controls?.elapsed = self.elapsed
                if self.settings?.menuBarTime == true { self.onMenuBarTime?(RecordingControlsModel.clock(self.elapsed)) }
                self.controls?.droppedFrames = recorder.stats.framesDropped
                if let master = self.master { self.controls?.bytes = FileSizeText.size(of: master) }
                if let limit = self.settings?.maximumSeconds, limit > 0, self.elapsed >= limit { self.stop() }
                if recorder.failure != nil { self.stop() }
                if turn % 30 == 0, Self.freeSpace() < Self.minimumFreeSpace {
                    self.stopReason = "stopped because the disk is almost full"
                    self.stop()
                }
            }
        }
    }

    private static func freeSpace() -> Int64 {
        let values = try? workFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    // MARK: Finishing

    private func finish() async {
        guard let recorder, let settings, let master else { return }
        state = .finishing
        controls?.isFinishing = true
        overlay?.stop()
        do {
            let size = (width: recorder.geometry.width, height: recorder.geometry.height)
            let stats = try await recorder.stop()
            tearDown()
            present(master: master, stats: stats, size: size, settings: settings)
        } catch {
            tearDown()
            // A movie written in fragments is usually playable even when closing it failed.
            if FileSizeText.size(of: master) > 100_000 {
                show(RecordingError.writer("\(error.localizedDescription)\n\nThe part already written was kept and will be offered again when CaptureDeck next opens."))
            } else {
                try? FileManager.default.removeItem(at: master)
                show(error)
            }
        }
    }

    private func tearDown() {
        ticker?.cancel()
        ticker = nil
        overlay?.stop()
        overlay = nil
        outline?.close()
        outline = nil
        controlsPanel?.close()
        controlsPanel = nil
        controls = nil
        recorder = nil
        settings = nil
        source = nil
        onMenuBarTime?(nil)
        master = nil
        runningSince = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        state = .idle
        afterRecording?()
    }

    private func present(master: URL, stats: RecordingStats, size: (width: Int, height: Int), settings: RecordingSettings) {
        let codec = EncoderSettings.effectiveCodec(settings.configuration.codec, width: size.width, height: size.height)
        let codecName = codec == .hevc ? "HEVC" : codec == .h264 ? "H.264" : codec == .proRes422 ? "ProRes 422" : "ProRes 4444"
        let summary = "\(size.width) × \(size.height)  ·  \(settings.configuration.frameRate.title)  ·  \(codecName)"
        var problems: [String] = []
        if let stopReason { problems.append(stopReason) }
        if stats.framesDropped > 0 { problems.append("\(stats.framesDropped) frames dropped: try a lower frame rate") }
        if stats.audioBuffersDropped > 0 { problems.append("some audio was lost") }
        for source in stats.silentSources { problems.append(source == .system ? "no sound from the Mac was captured" : "no sound from the microphone was captured") }
        review(master: master, duration: stats.duration, summary: summary, warning: problems.isEmpty ? nil : problems.joined(separator: ", "),
               codec: codec, settings: settings, automatic: !settings.showReview && problems.isEmpty)
    }

    private func review(master: URL, duration: Double, summary: String, warning: String?, codec: VideoCodec,
                        settings: RecordingSettings, automatic: Bool) {
        let name = master.deletingPathExtension().lastPathComponent
        let model = ReviewModel(master: master, duration: duration, summary: summary, warning: warning, name: name, format: settings.format,
                                formats: ExportFormat.available(for: codec), gifOptions: settings.gif, mixesAudio: settings.mixAudio,
                                audioBitrate: settings.configuration.audioBitrate,
                                workFolder: Self.workFolder.appendingPathComponent("Prepared/\(UUID().uuidString)"),
                                exactTrim: settings.exactTrim)
        guard automatic else { openReview(model, folder: settings.folder); return }
        Task {
            await model.waitUntilPrepared()
            guard case .ready(let bytes) = model.size else { openReview(model, folder: settings.folder); return }
            let destination = model.freeDestination(in: settings.folder)
            do {
                try model.save(to: destination)
                announceSaved(destination, bytes: bytes)
            } catch {
                openReview(model, folder: settings.folder)
            }
        }
    }

    private func openReview(_ model: ReviewModel, folder: URL) {
        let window = ReviewWindowController(
            model: model, saveFolder: folder,
            onSaved: { [weak self] url, bytes in self?.announceSaved(url, bytes: bytes) },
            onClosed: { [weak self] closed in
                self?.reviews.removeAll { $0 === closed }
                ActivationPolicyManager.shared.release(closed)
            })
        reviews.append(window)
        ActivationPolicyManager.shared.retain(window)
        window.show()
    }

    private func announceSaved(_ url: URL, bytes: Int64) {
        let alert = NSAlert()
        alert.messageText = "Recording saved (\(FileSizeText.text(bytes)))"
        alert.informativeText = (url.path as NSString).abbreviatingWithTildeInPath
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Copy File")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertSecondButtonReturn: NSWorkspace.shared.activateFileViewerSelecting([url])
        case .alertThirdButtonReturn:                                  // ready to paste into a chat, an email or a folder
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
        default: break
        }
    }

    // MARK: Quitting and recovery

    /// Closes a running recording properly before the app quits; it is offered again at the next launch.
    func finishForQuit() async {
        guard let recorder, state == .recording || state == .paused else { return }
        state = .finishing
        _ = try? await recorder.stop()
        tearDown()
    }

    /// Offers recordings that were never saved or discarded (a crash, or quitting before saving).
    func recoverUnsaved() {
        let manager = FileManager.default
        try? manager.removeItem(at: Self.workFolder.appendingPathComponent("Prepared"))
        let files = (try? manager.contentsOfDirectory(at: Self.workFolder, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "mov" {
            Task {
                let asset = AVURLAsset(url: url)
                let duration = (try? await asset.load(.duration).seconds) ?? 0
                let track = try? await asset.loadTracks(withMediaType: .video).first
                guard duration > 0, let track, let size = try? await track.load(.naturalSize) else {
                    try? manager.removeItem(at: url)                       // nothing playable in it
                    return
                }
                let isProRes = (try? await track.load(.formatDescriptions))?.contains {
                    [kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes4444].contains(CMFormatDescriptionGetMediaSubType($0))
                } ?? false
                let alert = NSAlert()
                alert.messageText = "An unsaved recording was found"
                alert.informativeText = "\(url.deletingPathExtension().lastPathComponent)\n\(RecordingControlsModel.clock(duration)) · \(FileSizeText.text(FileSizeText.size(of: url)))"
                alert.addButton(withTitle: "Review")
                alert.addButton(withTitle: "Later")
                alert.addButton(withTitle: "Delete").hasDestructiveAction = true
                NSApp.activate(ignoringOtherApps: true)
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    review(master: url, duration: duration, summary: "\(Int(size.width)) × \(Int(size.height))", warning: nil,
                           codec: isProRes ? .proRes422 : .hevc, settings: RecordingSettings(store: store), automatic: false)
                case .alertThirdButtonReturn:
                    try? manager.removeItem(at: url)
                default: break
                }
            }
        }
    }

    // MARK: Messages

    private func checkPermission() -> Bool {
        if ScreenRecordingPermission.isGranted { return true }
        if !store.bool(SettingID.screenRecordingAsked) {
            store.set(true, for: SettingID.screenRecordingAsked)
            return ScreenRecordingPermission.request()
        }
        showPermissionAlert()
        return false
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = "Enable CaptureDeck in System Settings > Privacy & Security > Screen Recording, then try again (you may need to reopen the app)."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { ScreenRecordingPermission.openSystemSettings() }
    }

    private func show(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Screen recording"
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
