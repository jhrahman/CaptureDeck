import AVFoundation
import CoreGraphics
import ImageIO
import Testing
@testable import RecordingEngine

/// Writes real movies from made-up pictures and sound, then reads the files back.
enum Synthetic {
    static let width = 640, height = 360
    static let origin = 5000.0                                     // an arbitrary host-clock start

    static func time(_ seconds: Double) -> CMTime { CMTime(seconds: origin + seconds, preferredTimescale: 1_000_000_000) }

    /// A flat picture whose grey level tells which picture it is.
    static func picture(gray: UInt8) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        let base = CVPixelBufferGetBaseAddress(buffer!)!
        memset(base, Int32(gray), CVPixelBufferGetBytesPerRow(buffer!) * height)
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        return buffer!
    }

    /// 1024 frames of a stereo 16-bit tone.
    static func tone(at seconds: Double, frequency: Double) -> CMSampleBuffer {
        let frames = 1024
        var samples = [Int16](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let value = Int16(sin(2 * .pi * frequency * (seconds + Double(i) / 48_000)) * 8000)
            samples[2 * i] = value
            samples[2 * i + 1] = value
        }
        var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &description)
        var block: CMBlockBuffer?
        let length = frames * 4
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: description!,
            sampleCount: frames, presentationTimeStamp: time(seconds), packetDescriptions: nil, sampleBufferOut: &sample)
        return sample!
    }

    static func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("capturedeck-test-\(UUID().uuidString)-\(name)")
    }

    /// Feeds `seconds` of capture in real time: a new picture at `pictureRate` until `stillFrom`, sound throughout, and
    /// an optional pause.
    static func record(_ configuration: RecordingConfiguration, seconds: Double, pictureRate: Double = 30, stillFrom: Double = .infinity,
                       pause: ClosedRange<Double>? = nil, audio: [AudioSource] = [.system, .microphone]) async throws -> (URL, RecordingStats) {
        let url = temporaryURL("master.mov")
        let writer = try MovieWriter(url: url, configuration: configuration, width: width, height: height, audioSources: audio)
        var nextPicture = 0.0, nextAudio = 0.0, nextTick = 0.0, paused = false, resumed = false
        let started = Date()
        var now = 0.0
        while now < seconds {
            if let pause, !paused, now >= pause.lowerBound { writer.pause(at: time(pause.lowerBound)); paused = true }
            if let pause, !resumed, now >= pause.upperBound { writer.resume(at: time(pause.upperBound)); resumed = true }
            while nextPicture <= now, nextPicture < min(stillFrom, seconds) {
                writer.appendVideo(picture(gray: UInt8(40 + Int(nextPicture * 20) % 180)), at: time(nextPicture))
                nextPicture += 1 / pictureRate
            }
            while nextAudio <= now {
                if audio.contains(.system) { writer.appendAudio(tone(at: nextAudio, frequency: 440), from: .system) }
                if audio.contains(.microphone) { writer.appendAudio(tone(at: nextAudio, frequency: 880), from: .microphone) }
                nextAudio += 1024.0 / 48_000
            }
            if nextTick <= now { writer.tick(at: time(now)); nextTick += 0.05 }
            try await Task.sleep(nanoseconds: 4_000_000)
            now = Date().timeIntervalSince(started)
        }
        let stats = try await writer.finish(at: time(seconds))
        return (url, stats)
    }

    static func videoTimes(_ url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() { if sample.imageBuffer != nil { times.append(sample.presentationTimeStamp.seconds) } }
        return times.sorted()
    }

    static func duration(_ url: URL, _ type: AVMediaType) async throws -> [Double] {
        var result: [Double] = []
        for track in try await AVURLAsset(url: url).loadTracks(withMediaType: type) {
            result.append(try await track.load(.timeRange).duration.seconds)
        }
        return result
    }
}

/// Serialized: each test feeds a recording in real time, and the encoder should not be shared between them.
@Suite(.serialized)
struct MovieWriterTests {
    @Test func aRecordingHasVideoBothAudioTracksAndTheRightLength() async throws {
        let (url, stats) = try await Synthetic.record(RecordingConfiguration(), seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(stats.framesDropped == 0 && stats.audioBuffersDropped == 0)
        let video = try await Synthetic.duration(url, .video), audio = try await Synthetic.duration(url, .audio)
        #expect(video.count == 1 && audio.count == 2)
        #expect(abs(video[0] - 2) < 0.1, "video \(video)")
        for track in audio { #expect(abs(track - 2) < 0.15, "audio \(audio)") }
        #expect(try await Synthetic.videoTimes(url).count == stats.framesWritten)       // every accepted frame is in the file
    }

    @Test func aPauseIsCutOutOfPictureAndSoundAlike() async throws {
        let (url, _) = try await Synthetic.record(RecordingConfiguration(), seconds: 3, pause: 1.0...2.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let video = try await Synthetic.duration(url, .video)[0]
        #expect(abs(video - 2) < 0.1, "video \(video)")
        for track in try await Synthetic.duration(url, .audio) { #expect(abs(track - video) < 0.15, "audio \(track) video \(video)") }
        let gaps = zip(try await Synthetic.videoTimes(url), try await Synthetic.videoTimes(url).dropFirst()).map { $1 - $0 }
        #expect((gaps.max() ?? 1) < 0.2, "a hole was left in the video: \(gaps.max() ?? 0)")
    }

    @Test func aStillScreenStillFillsTheWholeLength() async throws {
        let (url, stats) = try await Synthetic.record(RecordingConfiguration(), seconds: 3, stillFrom: 0.3, audio: [.system])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(abs(try await Synthetic.duration(url, .video)[0] - 3) < 0.1)
        #expect(stats.framesWritten < 25, "variable timing should store few frames of a still screen: \(stats.framesWritten)")
    }

    @Test(arguments: [FrameRate.fps25, .fps40, .fps60])
    func constantTimingGivesExactlyTheChosenFrameRate(_ rate: FrameRate) async throws {
        var configuration = RecordingConfiguration()
        configuration.frameRate = rate
        configuration.timing = .constant
        let (url, _) = try await Synthetic.record(configuration, seconds: 2, stillFrom: 0.5, audio: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let times = try await Synthetic.videoTimes(url)
        #expect(abs(times.count - rate.rawValue * 2) <= 1, "\(times.count) frames")
        for (a, b) in zip(times, times.dropFirst()) { #expect(abs((b - a) - 1 / Double(rate.rawValue)) < 0.001) }
    }

    @Test(arguments: VideoCodec.allCases)
    func everyCodecRecords(_ codec: VideoCodec) async throws {
        var configuration = RecordingConfiguration()
        configuration.codec = codec
        let (url, stats) = try await Synthetic.record(configuration, seconds: 0.6, audio: [])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(stats.framesWritten > 10)
    }

    @Test func sharpColorRecords() async throws {
        var configuration = RecordingConfiguration()
        configuration.sharpColor = true
        let (url, stats) = try await Synthetic.record(configuration, seconds: 0.6, audio: [])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(stats.framesWritten > 10)
    }

    @Test func anAudioSourceThatDeliversNothingIsReported() async throws {
        let url = Synthetic.temporaryURL("silent.mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try MovieWriter(url: url, configuration: RecordingConfiguration(), width: Synthetic.width, height: Synthetic.height,
                                     audioSources: [.system, .microphone])
        writer.appendVideo(Synthetic.picture(gray: 90), at: Synthetic.time(0))
        writer.appendAudio(Synthetic.tone(at: 0.01, frequency: 440), from: .system)
        let stats = try await writer.finish(at: Synthetic.time(0.5))
        #expect(stats.silentSources == [.microphone])
    }

    @Test func nothingCapturedIsReportedNotSaved() async throws {
        let url = Synthetic.temporaryURL("empty.mov")
        let writer = try MovieWriter(url: url, configuration: RecordingConfiguration(), width: 640, height: 360, audioSources: [])
        await #expect(throws: RecordingError.nothingRecorded) { try await writer.finish(at: Synthetic.time(1)) }
    }

    // MARK: Exact trim

    /// A small grey version of the frame shown at `seconds`, to tell which source frame it is.
    private func level(_ url: URL, at seconds: Double) async throws -> Int {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Int(pixel[0])
    }

    private func storedFrames(_ url: URL) async throws -> Int {
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)[0]
        let cursor = try #require(track.makeSampleCursorAtFirstSampleInDecodeOrder())
        var count = 1
        while cursor.stepInDecodeOrder(byCount: 1) == 1 { count += 1 }
        return count
    }

    /// The reason exact trim exists: nothing from outside the chosen range may remain in the file.
    @Test(arguments: [VideoCodec.hevc, .h264, .proRes422])
    func exactTrimLeavesNothingOfTheCutFootageInTheFile(_ codec: VideoCodec) async throws {
        var configuration = RecordingConfiguration()
        configuration.codec = codec
        let (master, _) = try await Synthetic.record(configuration, seconds: 5, audio: [.system])
        let exact = Synthetic.temporaryURL("exact.mov"), copied = Synthetic.temporaryURL("copied.mov")
        defer { for url in [master, exact, copied] { try? FileManager.default.removeItem(at: url) } }
        let range = CMTimeRange(start: CMTime(seconds: 3.3, preferredTimescale: 600), end: CMTime(seconds: 4.3, preferredTimescale: 600))

        try await RecordingExporter.exactTrim(master, to: exact, container: .mov, range: range, audioBitrate: 128_000)
        let shown = try await Synthetic.videoTimes(exact)
        #expect(try await storedFrames(exact) == shown.count, "hidden frames remain")
        #expect(abs(shown.count - 30) <= 2, "\(shown.count) frames")
        #expect(abs(try await AVURLAsset(url: exact).load(.duration).seconds - 1) < 0.05)
        for track in try await Synthetic.duration(exact, .audio) { #expect(abs(track - 1) < 0.1, "audio \(track)") }
        // It starts and continues on exactly the chosen frames (the test picture brightens every twentieth of a second).
        for offset in [0.0, 0.5, 0.95] {
            let wanted = try await level(master, at: 3.3 + offset), got = try await level(exact, at: offset)
            #expect(abs(wanted - got) <= 2, "at \(offset): \(got), source \(wanted)")
        }

        if codec != .proRes422 {                                     // every ProRes frame stands alone
            try await RecordingExporter.movie(master, to: copied, container: .mov, range: range)
            #expect(try await storedFrames(copied) > Synthetic.videoTimes(copied).count, "the quick copy is expected to keep hidden frames")
        }
    }

    /// A still screen stores few frames, so the frame on screen at the cut may be much older than the cut.
    @Test func exactTrimOfAStillStretchStartsWithThePictureThatWasShowing() async throws {
        let (master, _) = try await Synthetic.record(RecordingConfiguration(), seconds: 3, stillFrom: 0.4, audio: [])
        let exact = Synthetic.temporaryURL("still.mp4")
        defer { for url in [master, exact] { try? FileManager.default.removeItem(at: url) } }
        let range = CMTimeRange(start: CMTime(seconds: 1.2, preferredTimescale: 600), end: CMTime(seconds: 2.2, preferredTimescale: 600))
        try await RecordingExporter.exactTrim(master, to: exact, container: .mp4, range: range, audioBitrate: 128_000)
        #expect(abs(try await AVURLAsset(url: exact).load(.duration).seconds - 1) < 0.05)
        #expect(abs(try await level(exact, at: 0) - level(master, at: 1.2)) <= 2)
    }

    @Test func exactTrimKeepsTheSharperColorFormat() async throws {
        var configuration = RecordingConfiguration()
        configuration.sharpColor = true
        let (master, _) = try await Synthetic.record(configuration, seconds: 2, audio: [])
        let exact = Synthetic.temporaryURL("sharp.mov")
        defer { for url in [master, exact] { try? FileManager.default.removeItem(at: url) } }
        try await RecordingExporter.exactTrim(master, to: exact, container: .mov,
            range: CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600), end: CMTime(seconds: 1.5, preferredTimescale: 600)), audioBitrate: 128_000)
        func bits(_ url: URL) async throws -> Int? {
            let format = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)[0].load(.formatDescriptions)[0]
            return (CMFormatDescriptionGetExtensions(format) as? [String: Any])?["BitsPerComponent"] as? Int
        }
        #expect(try await bits(master) == 10)
        #expect(try await bits(exact) == 10)
    }

    // MARK: Export

    @Test func exportMixesAudioTrimsAndWritesEveryFormat() async throws {
        let (master, _) = try await Synthetic.record(RecordingConfiguration(), seconds: 4)
        let mixed = Synthetic.temporaryURL("mixed.mov"), mp4 = Synthetic.temporaryURL("out.mp4"), mov = Synthetic.temporaryURL("out.mov")
        let gif = Synthetic.temporaryURL("out.gif")
        defer { for url in [master, mixed, mp4, mov, gif] { try? FileManager.default.removeItem(at: url) } }

        let source = try await RecordingExporter.mixingAudio(master, to: mixed, bitrate: 160_000)
        #expect(source == mixed)
        #expect(try await Synthetic.duration(mixed, .audio).count == 1)
        // The video is copied, not encoded again: same frames.
        #expect(try await Synthetic.videoTimes(mixed).count == Synthetic.videoTimes(master).count)

        try await RecordingExporter.movie(source, to: mp4, container: .mp4)
        #expect(abs(try await Synthetic.duration(mp4, .video)[0] - 4) < 0.1)
        #expect(FileSizeText.size(of: mp4) > 1000)

        let range = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), end: CMTime(seconds: 2.5, preferredTimescale: 600))
        try await RecordingExporter.movie(source, to: mov, container: .mov, range: range)
        #expect(abs(try await AVURLAsset(url: mov).load(.duration).seconds - 1.5) < 0.1)

        try await RecordingExporter.gif(source, to: gif, options: GIFOptions(frameRate: 10, maximumWidth: 320), range: range)
        let image = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(image) == 15)
        #expect(CGImageSourceCreateImageAtIndex(image, 0, nil)?.width == 320)
    }
}
