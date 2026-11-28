import AVFoundation
import CoreMedia

public enum AudioSource: Sendable, CaseIterable { case system, microphone }

public enum RecordingError: Error, LocalizedError, Equatable {
    case permissionDenied
    case microphoneDenied
    case sourceUnavailable
    case unsupportedSettings
    case nothingRecorded
    case writer(String)
    case export(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "CaptureDeck needs the Screen Recording permission."
        case .microphoneDenied: "CaptureDeck is not allowed to use the microphone. Enable it in System Settings > Privacy & Security > Microphone, or turn the microphone off in Settings > Recording."
        case .sourceUnavailable: "The screen or window to record is no longer available."
        case .unsupportedSettings: "This Mac cannot encode video with these settings. Try another codec or quality in Settings > Recording."
        case .nothingRecorded: "Nothing was recorded."
        case .writer(let message): "The recording could not be written: \(message)"
        case .export(let message): "The video could not be prepared: \(message)"
        }
    }
}

public struct RecordingStats: Sendable, Equatable {
    public var duration: Double = 0
    public var framesWritten = 0
    /// Frames the encoder or disk could not take in time. Zero in a healthy recording; never hidden from the user.
    public var framesDropped = 0
    public var audioBuffersDropped = 0
    /// Audio sources that were asked for but never delivered a single sound buffer.
    public var silentSources: [AudioSource] = []
}

/// Writes one recording to a QuickTime movie: video plus up to two audio tracks (system sound and microphone), all on one
/// timeline. The movie is written in fragments, so it stays playable even if the app or the Mac dies mid-recording.
///
/// Everything runs on one private queue, so samples may arrive from any thread.
public final class MovieWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "capturedeck.recording.writer", qos: .userInteractive)
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var audioInputs: [AudioSource: AVAssetWriterInput] = [:]
    private let frameRate: Int
    private let timing: FrameTiming
    /// How often a still picture is stored again in variable timing: keeps seeking, audio interleaving and recovery working.
    private let heartbeat = 0.5

    private var timeline = RecordingTimeline()
    private var lastBuffer: CVPixelBuffer?
    private var lastVideoTime = CMTime.invalid
    private var audioEnd: [AudioSource: CMTime] = [:]
    private var stats = RecordingStats()
    private var heard: Set<AudioSource> = []
    private var finished = false
    public let url: URL

    public init(url: URL, configuration: RecordingConfiguration, width: Int, height: Int, audioSources: [AudioSource]) throws {
        self.url = url
        frameRate = configuration.frameRate.rawValue
        timing = configuration.timing
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mov) } catch { throw RecordingError.writer(error.localizedDescription) }
        writer.movieFragmentInterval = CMTime(seconds: 4, preferredTimescale: 600)

        let settings = EncoderSettings.video(configuration, width: width, height: height)
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw RecordingError.unsupportedSettings }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(videoInput) else { throw RecordingError.unsupportedSettings }
        writer.add(videoInput)

        for source in AudioSource.allCases where audioSources.contains(source) {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: EncoderSettings.audio(bitrate: configuration.audioBitrate))
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecordingError.unsupportedSettings }
            writer.add(input)
            audioInputs[source] = input
        }
        guard writer.startWriting() else { throw RecordingError.writer(writer.error?.localizedDescription ?? "unknown") }
        writer.startSession(atSourceTime: .zero)
    }

    /// The failure that stopped the writer, if any (a full disk, for instance).
    public var failure: RecordingError? {
        queue.sync { writer.status == .failed ? .writer(writer.error?.localizedDescription ?? "unknown") : nil }
    }

    public var currentStats: RecordingStats { queue.sync { stats } }

    // MARK: Video

    /// A new picture of the screen, captured at `time` (host clock). The movie starts with the first one.
    public func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime) {
        let box = Box(buffer)
        queue.async { [self] in
            guard !finished else { return }
            if timeline.start == nil, !timeline.isPaused { timeline.begin(at: time) }
            lastBuffer = box.value                           // kept even while paused: it is what the screen shows on resume
            guard let movieTime = timeline.movieTime(for: time) else { return }
            switch timing {
            case .variable: write(box.value, at: movieTime)
            case .constant: fill(upTo: movieTime, final: box.value)
            }
        }
    }

    /// Called regularly (host clock). Repeats a still picture, so time passes in the file while the screen does not change.
    public func tick(at time: CMTime) {
        queue.async { [self] in
            guard !finished, let buffer = lastBuffer, let now = timeline.movieTime(for: time), lastVideoTime.isValid else { return }
            switch timing {
            case .variable:
                if (now - lastVideoTime).seconds >= heartbeat { write(buffer, at: now) }
            case .constant:
                // Leave a little room for a real frame that is still on its way.
                fill(upTo: now - CMTime(seconds: 0.1, preferredTimescale: 600), final: buffer)
            }
        }
    }

    /// Constant frame rate: every slot of the frame grid up to `time` gets a picture.
    private func fill(upTo time: CMTime, final buffer: CVPixelBuffer) {
        let slot = Int64((time.seconds * Double(frameRate)).rounded())
        var next = lastVideoTime.isValid ? Int64((lastVideoTime.seconds * Double(frameRate)).rounded()) + 1 : 0
        while next <= slot {
            write(buffer, at: CMTime(value: next, timescale: CMTimeScale(frameRate)))
            next += 1
        }
    }

    private func write(_ buffer: CVPixelBuffer, at time: CMTime) {
        guard writer.status == .writing, !lastVideoTime.isValid || time > lastVideoTime else { return }
        guard videoInput.isReadyForMoreMediaData, adaptor.append(buffer, withPresentationTime: time) else {
            stats.framesDropped += 1
            return
        }
        lastVideoTime = time
        stats.framesWritten += 1
        stats.duration = max(stats.duration, time.seconds)
    }

    // MARK: Audio

    /// Audio captured at the buffer's own presentation time (host clock).
    public func appendAudio(_ sample: CMSampleBuffer, from source: AudioSource) {
        let box = Box(sample)
        queue.async { [self] in
            guard !finished, writer.status == .writing, let input = audioInputs[source],
                  let time = timeline.movieTime(for: box.value.presentationTimeStamp),
                  time >= (audioEnd[source] ?? .zero) - CMTime(value: 1, timescale: 1000),
                  let moved = Self.retimed(box.value, to: time) else { return }
            guard input.isReadyForMoreMediaData, input.append(moved) else { stats.audioBuffersDropped += 1; return }
            audioEnd[source] = time + box.value.duration
            heard.insert(source)
        }
    }

    static func retimed(_ sample: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        let shift = time - sample.presentationTimeStamp
        for index in timings.indices {
            timings[index].presentationTimeStamp = timings[index].presentationTimeStamp + shift
            if timings[index].decodeTimeStamp.isValid { timings[index].decodeTimeStamp = timings[index].decodeTimeStamp + shift }
        }
        var result: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timings, sampleBufferOut: &result)
        return result
    }

    // MARK: Pause and finish

    public func pause(at time: CMTime) { queue.async { [self] in timeline.pause(at: time) } }

    public func resume(at time: CMTime) {
        queue.async { [self] in
            guard timeline.isPaused else { return }
            timeline.resume(at: time)
            if timeline.start == nil { return }
            if let buffer = lastBuffer, let movieTime = timeline.movieTime(for: time) {
                if timing == .variable { write(buffer, at: movieTime) }
            }
        }
    }

    /// Ends the movie at `time` (host clock) and closes the file.
    public func finish(at time: CMTime) async throws -> RecordingStats {
        let end: CMTime = queue.sync {
            finished = true
            let end = timeline.duration(at: time)
            // A last copy of the picture, so the movie lasts until the moment of stopping even if the screen was still.
            if let buffer = lastBuffer, lastVideoTime.isValid {
                let frame = CMTime(value: 1, timescale: CMTimeScale(frameRate))
                if timing == .constant { fill(upTo: end - frame, final: buffer) } else if end - frame > lastVideoTime { write(buffer, at: end - frame) }
            }
            videoInput.markAsFinished()
            audioInputs.values.forEach { $0.markAsFinished() }
            return end
        }
        guard queue.sync(execute: { stats.framesWritten }) > 0 else {
            writer.cancelWriting()
            throw RecordingError.nothingRecorded
        }
        if writer.status == .writing {
            writer.endSession(atSourceTime: CMTimeMaximum(end, lastVideoTime))
            await writer.finishWriting()
        }
        guard writer.status == .completed else { throw RecordingError.writer(writer.error?.localizedDescription ?? "unknown") }
        return queue.sync {
            var result = stats
            result.silentSources = AudioSource.allCases.filter { audioInputs[$0] != nil && !heard.contains($0) }
            result.duration = CMTimeMaximum(end, lastVideoTime).seconds
            return result
        }
    }

    public func cancel() {
        queue.sync { finished = true; if writer.status == .writing { writer.cancelWriting() } }
        try? FileManager.default.removeItem(at: url)
    }

    /// Core Media's buffers are safe to hand to the writer's queue; the compiler cannot know that.
    private struct Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}
