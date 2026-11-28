import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ExportFormat: String, CaseIterable, Sendable {
    case mp4, mov, gif

    public var title: String {
        switch self {
        case .mp4: "MP4 (MPEG-4)"
        case .mov: "MOV (QuickTime)"
        case .gif: "Animated GIF"
        }
    }

    public var fileExtension: String { rawValue }

    /// MP4 cannot carry ProRes.
    public static func available(for codec: VideoCodec) -> [ExportFormat] { codec.isProRes ? [.mov, .gif] : [.mp4, .mov, .gif] }
}

public struct GIFOptions: Sendable, Equatable {
    public var frameRate: Int
    public var maximumWidth: Int
    public init(frameRate: Int = 12, maximumWidth: Int = 960) {
        self.frameRate = frameRate
        self.maximumWidth = maximumWidth
    }
    /// GIF has no streaming writer: every frame is held until the file is written, so long recordings are refused.
    public static let maximumDuration = 90.0
}

/// Turns the recorded movie into the file the user keeps. The video is copied bit for bit (never encoded a second time), so
/// exporting is fast and loses nothing.
public enum RecordingExporter {
    /// Many players play only the first audio track, so system sound and microphone are mixed into one. Returns `source`
    /// itself if there is nothing to mix.
    public static func mixingAudio(_ source: URL, to destination: URL, bitrate: Int) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard audio.count > 1, let video = try await asset.loadTracks(withMediaType: .video).first else { return source }

        try? FileManager.default.removeItem(at: destination)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: nil)          // compressed, as recorded
        let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(videoOutput)
        reader.add(audioOutput)
        let format = try await video.load(.formatDescriptions).first
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: EncoderSettings.audio(bitrate: bitrate))
        writer.add(videoInput)
        writer.add(audioInput)
        guard reader.startReading(), writer.startWriting() else {
            throw RecordingError.export(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)
        await withTaskGroup(of: Void.self) { group in
            for pair in [Pump(videoOutput, videoInput), Pump(audioOutput, audioInput)] {
                group.addTask { await pair.run() }
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed, reader.status == .completed else {
            throw RecordingError.export(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "unknown")
        }
        return destination
    }

    private final class Pump: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        init(_ output: AVAssetReaderOutput, _ input: AVAssetWriterInput) { (self.output, self.input) = (output, input) }

        func run() async {
            let queue = DispatchQueue(label: "capturedeck.recording.mix")
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    while input.isReadyForMoreMediaData {
                        guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                            input.markAsFinished()
                            done.resume()
                            return
                        }
                    }
                }
            }
        }
    }

    /// Writes `source`, optionally cut to `range`, as MP4 or MOV.
    public static func movie(_ source: URL, to destination: URL, container: MovieContainer, range: CMTimeRange? = nil) async throws {
        try? FileManager.default.removeItem(at: destination)
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough) else {
            throw RecordingError.export("This recording cannot be exported.")
        }
        session.outputURL = destination
        session.outputFileType = container.fileType
        session.shouldOptimizeForNetworkUse = true                // the index goes first, so web players can start at once
        if let range { session.timeRange = range }
        let box = Session(session)
        await withTaskCancellationHandler {
            await box.session.export()
        } onCancel: {
            box.session.cancelExport()
        }
        try Task.checkCancellation()
        guard session.status == .completed else { throw RecordingError.export(session.error?.localizedDescription ?? "unknown") }
    }

    private struct Session: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    public static func gif(_ source: URL, to destination: URL, options: GIFOptions, range: CMTimeRange? = nil) async throws {
        let asset = AVURLAsset(url: source)
        let length = try await asset.load(.duration)
        let span = range ?? CMTimeRange(start: .zero, duration: length)
        guard span.duration.seconds <= GIFOptions.maximumDuration else {
            throw RecordingError.export("GIF is only practical for short clips. Trim to \(Int(GIFOptions.maximumDuration)) seconds or less, or choose MP4.")
        }
        let rate = max(1, min(options.frameRate, 50))
        let count = max(1, Int((span.duration.seconds * Double(rate)).rounded(.down)))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: options.maximumWidth, height: 100_000)

        try? FileManager.default.removeItem(at: destination)
        guard let file = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw RecordingError.export("The GIF could not be created.")
        }
        CGImageDestinationSetProperties(file, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        // GIF times are in hundredths of a second: round the running total, so the length does not drift.
        var shown = 0
        for index in 0..<count {
            try Task.checkCancellation()
            let time = span.start + CMTime(value: CMTimeValue(index), timescale: CMTimeScale(rate))
            let image = try await generator.image(at: time).image
            let end = Int((Double(index + 1) * 100 / Double(rate)).rounded())
            let delay = Double(end - shown) / 100
            shown = end
            CGImageDestinationAddImage(file, image, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(file) else { throw RecordingError.export("The GIF could not be written.") }
    }
}

public enum FileSizeText {
    public static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// "812 KB", "24.6 MB", "1.32 GB" (decimal units, as Finder shows them).
    public static func text(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value < 1_000_000 { return "\(Int((value / 1_000).rounded())) KB" }
        if value < 999_950_000 { return String(format: "%.1f MB", value / 1_000_000) }
        return String(format: "%.2f GB", value / 1_000_000_000)
    }
}
