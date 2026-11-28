import AVFoundation

/// Cuts a recording to a range by decoding and encoding it again, so that the new file holds *only* what is inside the
/// range, starting on exactly the chosen frame.
///
/// Copying the compressed video instead is faster and lossless, but a video can only be cut at a key frame: the file then
/// still carries the footage before the cut (hidden by an edit list, recoverable by other tools).
extension RecordingExporter {
    public static func exactTrim(_ source: URL, to destination: URL, container: MovieContainer, range: CMTimeRange, audioBitrate: Int,
                                 progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw RecordingError.export("There is no video to trim.") }
        let size = try await video.load(.naturalSize)
        let format = try await video.load(.formatDescriptions).first
        let rate = try await video.load(.nominalFrameRate)
        let subtype = format.map(CMFormatDescriptionGetMediaSubType) ?? kCMVideoCodecType_HEVC

        var configuration = RecordingConfiguration()
        configuration.quality = .maximum                          // a second encoding should cost as little sharpness as possible
        configuration.frameRate = FrameRate.allCases.last { Float($0.rawValue) <= max(rate, 15) + 1 } ?? .fps60
        let pixelFormat: OSType
        switch subtype {
        case kCMVideoCodecType_H264:
            configuration.codec = .h264
            pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case kCMVideoCodecType_AppleProRes422:
            configuration.codec = .proRes422
            pixelFormat = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        case kCMVideoCodecType_AppleProRes4444:
            configuration.codec = .proRes4444
            pixelFormat = kCVPixelFormatType_4444AYpCbCr16
        default:
            configuration.codec = .hevc
            // 10-bit 4:2:2 ("sharper colored text") recordings stay that way.
            let extensions = format.flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] }
            let atoms = extensions?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any]
            let profile = (atoms?["hvcC"] as? Data).flatMap { $0.count > 1 ? $0[$0.startIndex + 1] & 0x1F : nil }
            configuration.sharpColor = profile == 4                // HEVC range extensions
            pixelFormat = configuration.sharpColor ? kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }

        try? FileManager.default.removeItem(at: destination)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let writer = try AVAssetWriter(outputURL: destination, fileType: container.fileType)
        writer.shouldOptimizeForNetworkUse = true

        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
        reader.add(videoOutput)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: EncoderSettings.video(configuration, width: Int(size.width), height: Int(size.height)))
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        writer.add(videoInput)

        var audio: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: EncoderSettings.audio(bitrate: audioBitrate))
            input.expectsMediaDataInRealTime = false
            reader.add(output)
            writer.add(input)
            audio.append((output, input))
        }
        guard reader.startReading(), writer.startWriting() else {
            throw RecordingError.export(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let job = TrimJob(range: range, progress: progress)
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                let pictures = Trimmed(videoOutput, videoInput, adaptor)
                group.addTask { await job.video(pictures) }
                for pair in audio {
                    let sound = Trimmed(pair.0, pair.1, nil)
                    group.addTask { await job.audio(sound) }
                }
            }
        } onCancel: {
            job.cancel()
        }
        if Task.isCancelled || job.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        }
        writer.endSession(atSourceTime: range.duration)
        await writer.finishWriting()
        guard writer.status == .completed, reader.status == .completed else {
            throw RecordingError.export(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "unknown")
        }
    }
}

private struct Trimmed: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor?
    init(_ output: AVAssetReaderOutput, _ input: AVAssetWriterInput, _ adaptor: AVAssetWriterInputPixelBufferAdaptor?) {
        (self.output, self.input, self.adaptor) = (output, input, adaptor)
    }
}

/// Moves decoded samples into the encoder, with times counted from the start of the range.
private final class TrimJob: @unchecked Sendable {
    private let range: CMTimeRange
    private let progress: (@Sendable (Double) -> Void)?
    private let lock = NSLock()
    private var cancelled = false

    init(range: CMTimeRange, progress: (@Sendable (Double) -> Void)?) { (self.range, self.progress) = (range, progress) }

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }

    func video(_ track: Trimmed) async {
        // The picture on screen at the start of the range was usually captured before it (a still screen stores few frames):
        // the last frame at or before the start becomes the first frame of the new file.
        var opening: CVPixelBuffer?
        var opened = false
        var pending: (CVPixelBuffer, CMTime)?
        var last = CMTime.invalid
        await feed(track.input, label: "video") { [self] in
            if let (buffer, time) = pending {
                guard track.adaptor?.append(buffer, withPresentationTime: time) == true else { return false }
                pending = nil
                last = time
                progress?(min(1, max(0, time.seconds / max(range.duration.seconds, 0.001))))
                return true
            }
            guard let sample = track.output.copyNextSampleBuffer() else {
                if !opened, let first = opening { opened = true; pending = (first, .zero); return true }
                return false
            }
            guard let buffer = sample.imageBuffer else { return true }
            let time = sample.presentationTimeStamp - range.start
            if !opened {
                if time <= .zero { opening = buffer; return true }
                opened = true
                if let first = opening { _ = track.adaptor?.append(first, withPresentationTime: .zero); last = .zero }
            }
            if time < range.duration, !last.isValid || time > last { pending = (buffer, last.isValid ? time : .zero) }
            return true
        }
    }

    func audio(_ track: Trimmed) async {
        await feed(track.input, label: "audio") { [self] in
            guard let sample = track.output.copyNextSampleBuffer() else { return false }
            let time = sample.presentationTimeStamp - range.start
            guard time >= .zero, time < range.duration else { return true }
            guard let moved = MovieWriter.retimed(sample, to: time) else { return true }
            return track.input.append(moved)
        }
    }

    /// Calls `step` whenever the encoder wants more, until it returns false or the job is cancelled.
    private func feed(_ input: AVAssetWriterInput, label: String, step: @escaping () -> Bool) async {
        let queue = DispatchQueue(label: "capturedeck.recording.trim.\(label)")
        let work = Unchecked(step: step, input: input)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            work.input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !finished else { return }
                while work.input.isReadyForMoreMediaData {
                    if isCancelled || !work.step() {
                        finished = true
                        work.input.markAsFinished()
                        done.resume()
                        return
                    }
                }
            }
        }
    }

    private struct Unchecked: @unchecked Sendable {
        let step: () -> Bool
        let input: AVAssetWriterInput
    }
}
