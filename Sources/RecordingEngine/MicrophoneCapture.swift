@preconcurrency import AVFoundation
import CoreMedia

public struct Microphone: Sendable, Equatable {
    public let id: String
    public let name: String

    public static func available() -> [Microphone] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) { types = [.microphone, .external] } else { types = [.builtInMicrophone, .externalUnknown] }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified).devices
            .map { Microphone(id: $0.uniqueID, name: $0.localizedName) }
    }
}

/// Records the microphone, with every buffer's time converted to the host clock that the screen frames use.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "capturedeck.recording.microphone", qos: .userInteractive)
    private let lock = NSLock()
    private var muted = false
    private var level: Float = 0
    private let onSample: @Sendable (CMSampleBuffer) -> Void

    init(deviceID: String?, onSample: @escaping @Sendable (CMSampleBuffer) -> Void) throws {
        self.onSample = onSample
        super.init()
        let chosen = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) }           // unplugged since it was chosen: use the default
        guard let device = chosen ?? AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            throw RecordingError.writer("No microphone is available.")
        }
        session.addInput(input)
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw RecordingError.writer("The microphone cannot be used.") }
        session.addOutput(output)
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    func start() { queue.async { [session] in session.startRunning() } }
    func stop() { queue.sync { session.stopRunning() } }

    /// While muted the track continues as silence, so it stays in step with the picture.
    var isMuted: Bool {
        get { lock.withLock { muted } }
        set { lock.withLock { muted = newValue } }
    }

    /// How loud the microphone is right now, 0...1, for the on-screen meter.
    var currentLevel: Float { lock.withLock { muted ? 0 : level } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        let decibels = connection.audioChannels.map(\.averagePowerLevel).max() ?? -160
        let silent = lock.withLock { () -> Bool in
            level = max(0, min(1, (decibels + 50) / 50))
            return muted
        }
        if silent, let data = CMSampleBufferGetDataBuffer(sample) {
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0, dataLength: CMBlockBufferGetDataLength(data))
        }
        let hostClock = CMClockGetHostTimeClock()
        let sessionClock: CMClock?
        if #available(macOS 12.3, *) { sessionClock = session.synchronizationClock } else { sessionClock = session.masterClock }
        guard let sessionClock, sessionClock != hostClock else { onSample(sample); return }
        let hostTime = CMSyncConvertTime(sample.presentationTimeStamp, from: sessionClock, to: hostClock)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: hostTime, decodeTimeStamp: .invalid)
        var converted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &converted)
        if let converted { onSample(converted) }
    }
}
