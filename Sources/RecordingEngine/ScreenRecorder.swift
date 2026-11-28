import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

/// The exact pixels to record: which part of the screen, at what size. Kept apart from ScreenCaptureKit so the
/// no-resampling arithmetic can be tested.
public struct CaptureGeometry: Equatable, Sendable {
    /// In the display's point coordinates.
    public let sourceRect: CGRect
    public let width: Int
    public let height: Int

    /// `rect` is in points and `scale` is video pixels per point. The video size is made even by trimming at most one pixel,
    /// and the captured rectangle is then exactly that many pixels, on the pixel grid: nothing is stretched or blurred.
    public static func make(rect: CGRect, scale: CGFloat) -> CaptureGeometry {
        let left = (rect.minX * scale).rounded(), top = (rect.minY * scale).rounded()
        let size = EncoderSettings.evenSize(width: Double((rect.width * scale).rounded()), height: Double((rect.height * scale).rounded()))
        return CaptureGeometry(sourceRect: CGRect(x: left / scale, y: top / scale, width: CGFloat(size.width) / scale, height: CGFloat(size.height) / scale),
                               width: size.width, height: size.height)
    }
}

/// Records a display, a region or a window, with system sound and microphone, into a movie file.
public final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let configuration: RecordingConfiguration
    private let source: RecordingSource
    private let videoQueue = DispatchQueue(label: "capturedeck.recording.frames", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "capturedeck.recording.systemaudio", qos: .userInteractive)

    private var stream: SCStream?
    /// Window recordings only: a second stream that listens to the whole Mac.
    private var soundStream: SCStream?
    private var writer: MovieWriter?
    private var microphone: MicrophoneCapture?
    private var timer: DispatchSourceTimer?
    private var follower: Task<Void, Never>?
    public private(set) var geometry = CaptureGeometry(sourceRect: .zero, width: 0, height: 0)

    /// Called (on any thread) when macOS ends the capture by itself: the display was unplugged, the window closed, or the
    /// user stopped sharing from the system menu. What was recorded is still saved by calling `stop`.
    public var onInterrupted: (@Sendable (String) -> Void)?

    public init(source: RecordingSource, configuration: RecordingConfiguration) {
        self.source = source
        self.configuration = configuration
    }

    private static var now: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    /// - Parameters:
    ///   - excludedWindows: CaptureDeck's own controls, which must not appear in the video.
    ///   - overlayWindows: click and keystroke highlights, which must appear even when recording a single window.
    public func start(writingTo url: URL, excludedWindows: [CGWindowID] = [], overlayWindows: [CGWindowID] = []) async throws {
        if configuration.capturesMicrophone {
            guard await MicrophoneCapture.requestAccess() else { throw RecordingError.microphoneDenied }
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw RecordingError.permissionDenied
        }

        let filter: SCContentFilter
        let streamConfiguration = SCStreamConfiguration()
        var followedWindow: (id: CGWindowID, display: SCDisplay)?
        // A capture that shows only one window hears only that window's app (often nothing at all), so "the Mac's sound"
        // then needs its own stream over the whole display.
        var soundDisplay: SCDisplay?

        switch source {
        case .display(let id), .region(_, let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw RecordingError.sourceUnavailable }
            filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { excludedWindows.contains($0.windowID) })
            var rect = CGRect(x: 0, y: 0, width: display.width, height: display.height)
            if case .region(let chosen, _) = source { rect = chosen.intersection(rect) }
            guard rect.width >= 16, rect.height >= 16 else { throw RecordingError.sourceUnavailable }
            geometry = .make(rect: rect, scale: configuration.scale == .native ? Self.pixelScale(of: id) : 1)
            streamConfiguration.sourceRect = geometry.sourceRect
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }),
                  let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) else { throw RecordingError.sourceUnavailable }
            if configuration.capturesSystemAudio { soundDisplay = display }
            let scale = configuration.scale == .native ? Self.pixelScale(of: display.displayID) : 1
            geometry = .make(rect: CGRect(origin: .zero, size: window.frame.size), scale: scale)
            let overlays = content.windows.filter { overlayWindows.contains($0.windowID) }
            if overlays.isEmpty {
                filter = SCContentFilter(desktopIndependentWindow: window)      // follows the window wherever it goes
            } else {
                // The highlights are separate windows, so record the display showing only these, cut to the window.
                filter = SCContentFilter(display: display, including: [window] + overlays)
                streamConfiguration.sourceRect = Self.local(window.frame, in: display)
                followedWindow = (id, display)
            }
        }

        streamConfiguration.width = geometry.width
        streamConfiguration.height = geometry.height
        streamConfiguration.minimumFrameInterval = Self.frameInterval(configuration.frameRate)
        streamConfiguration.queueDepth = 8
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA          // full colour in; the encoder does the converting
        streamConfiguration.colorSpaceName = CGColorSpace.sRGB
        streamConfiguration.showsCursor = configuration.showsCursor
        let soundWithPicture = configuration.capturesSystemAudio && soundDisplay == nil
        if soundWithPicture { addSound(to: streamConfiguration) }

        var audio: [AudioSource] = []
        if configuration.capturesSystemAudio { audio.append(.system) }
        if configuration.capturesMicrophone { audio.append(.microphone) }
        let writer = try MovieWriter(url: url, configuration: configuration, width: geometry.width, height: geometry.height, audioSources: audio)
        self.writer = writer

        do {
            if configuration.capturesMicrophone {
                microphone = try MicrophoneCapture(deviceID: configuration.microphoneID) { [weak writer] sample in
                    writer?.appendAudio(sample, from: .microphone)
                }
            }
            let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            if soundWithPicture { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
            self.stream = stream
            try await stream.startCapture()
            if let soundDisplay {
                let listening = SCStreamConfiguration()
                listening.width = 2                                     // its picture is never used: keep it as cheap as possible
                listening.height = 2
                listening.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                addSound(to: listening)
                let sound = SCStream(filter: SCContentFilter(display: soundDisplay, excludingWindows: []), configuration: listening, delegate: nil)
                try sound.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
                soundStream = sound
                try await sound.startCapture()
            }
        } catch {
            await shutDown()
            writer.cancel()
            self.writer = nil
            throw (error as? RecordingError) ?? RecordingError.writer(error.localizedDescription)
        }
        microphone?.start()

        let timer = DispatchSource.makeTimerSource(queue: videoQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.writer?.tick(at: Self.now) }
        timer.resume()
        self.timer = timer

        if let followedWindow { follow(followedWindow.id, on: followedWindow.display, configuration: streamConfiguration) }
    }

    private func addSound(to streamConfiguration: SCStreamConfiguration) {
        streamConfiguration.capturesAudio = true
        streamConfiguration.excludesCurrentProcessAudio = configuration.excludesOwnAudio
        streamConfiguration.sampleRate = 48_000
        streamConfiguration.channelCount = 2
    }

    /// A little shorter than a whole frame, so a screen refresh that arrives a hair early is not skipped.
    static func frameInterval(_ rate: FrameRate) -> CMTime { CMTime(value: 95, timescale: CMTimeScale(rate.rawValue * 100)) }

    private static func pixelScale(of id: CGDirectDisplayID) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return 1 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }

    private static func local(_ frame: CGRect, in display: SCDisplay) -> CGRect {
        frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    }

    /// Keeps the captured rectangle on a window that is being moved (only needed while highlights are on).
    private func follow(_ id: CGWindowID, on display: SCDisplay, configuration: SCStreamConfiguration) {
        let box = Unchecked((stream: stream, configuration: configuration, display: display))
        follower = Task {
            var last = box.value.configuration.sourceRect
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first
                guard let dictionary = info?[kCGWindowBounds as String] as? NSDictionary,
                      let frame = CGRect(dictionaryRepresentation: dictionary) else { continue }
                let rect = Self.local(frame, in: box.value.display)
                guard rect != last else { continue }
                last = rect
                box.value.configuration.sourceRect = rect
                try? await box.value.stream?.updateConfiguration(box.value.configuration)
            }
        }
    }

    private struct Unchecked<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    // MARK: While recording

    public func pause() { writer?.pause(at: Self.now) }
    public func resume() { writer?.resume(at: Self.now) }

    public var isMicrophoneMuted: Bool {
        get { microphone?.isMuted ?? false }
        set { microphone?.isMuted = newValue }
    }
    public var microphoneLevel: Float { microphone?.currentLevel ?? 0 }
    public var stats: RecordingStats { writer?.currentStats ?? RecordingStats() }
    public var failure: RecordingError? { writer?.failure }

    /// Stops and closes the movie. The length ends at the moment of this call.
    public func stop() async throws -> RecordingStats {
        let end = Self.now
        let writer = self.writer
        await shutDown()
        guard let writer else { throw RecordingError.nothingRecorded }
        self.writer = nil
        return try await writer.finish(at: end)
    }

    /// Stops and deletes everything.
    public func discard() async {
        let writer = self.writer
        self.writer = nil
        await shutDown()
        writer?.cancel()
    }

    private func shutDown() async {
        follower?.cancel()
        follower = nil
        timer?.cancel()
        timer = nil
        microphone?.stop()
        microphone = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil
        if let soundStream { try? await soundStream.stopCapture() }
        soundStream = nil
        videoQueue.sync {}
        audioQueue.sync {}
    }

    // MARK: ScreenCaptureKit

    public func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,   // "idle" carries no picture
                  let buffer = sample.imageBuffer else { return }
            writer?.appendVideo(buffer, at: sample.presentationTimeStamp)
        case .audio:
            writer?.appendAudio(sample, from: .system)
        default: break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onInterrupted?(error.localizedDescription)
    }
}
