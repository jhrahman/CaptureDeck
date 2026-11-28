import AVFoundation
import CoreGraphics
import VideoToolbox

/// Everything the user can choose about a recording. The raw values are what Settings stores.

/// The common film, broadcast and screen frame rates.
public enum FrameRate: Int, CaseIterable, Sendable {
    case fps15 = 15, fps24 = 24, fps25 = 25, fps30 = 30, fps40 = 40, fps50 = 50, fps60 = 60, fps90 = 90, fps120 = 120
    public var title: String { "\(rawValue) fps" }
}

public enum VideoCodec: String, CaseIterable, Sendable {
    case hevc, h264, proRes422, proRes4444

    public var title: String {
        switch self {
        case .hevc: "HEVC (H.265) – small and sharp"
        case .h264: "H.264 – plays almost everywhere"
        case .proRes422: "ProRes 422 – editing, very large"
        case .proRes4444: "ProRes 4444 – full color detail, huge"
        }
    }

    public var isProRes: Bool { self == .proRes422 || self == .proRes4444 }

    var avType: AVVideoCodecType {
        switch self {
        case .hevc: .hevc
        case .h264: .h264
        case .proRes422: .proRes422
        case .proRes4444: .proRes4444
        }
    }
}

/// The encoder's constant-quality level: it spends as many bits as each picture needs, so a still screen costs very little.
public enum VideoQuality: String, CaseIterable, Sendable {
    case compact, balanced, high, maximum

    public var title: String {
        switch self {
        case .compact: "Compact – smallest files"
        case .balanced: "Balanced"
        case .high: "High – crisp text (recommended)"
        case .maximum: "Maximum – larger files"
        }
    }

    var factor: Double {
        switch self {
        case .compact: 0.55
        case .balanced: 0.65
        case .high: 0.75
        case .maximum: 0.85
        }
    }
}

public enum ResolutionScale: String, CaseIterable, Sendable {
    /// Every pixel of the screen, never resampled.
    case native
    /// One video pixel per screen point (half of a Retina screen): much smaller files, softer text.
    case standard

    public var title: String { self == .native ? "Native – every screen pixel" : "Standard – half size on Retina, smaller files" }
}

public enum FrameTiming: String, CaseIterable, Sendable {
    /// A frame is stored when the screen changes (and at least twice a second).
    case variable
    /// Exactly the chosen number of frames every second, repeating the picture while nothing changes.
    case constant

    public var title: String { self == .variable ? "Variable – smaller files" : "Constant – for video editors" }
}

public enum MovieContainer: String, CaseIterable, Sendable {
    case mp4, mov
    public var title: String { self == .mp4 ? "MP4 (MPEG-4)" : "MOV (QuickTime)" }
    public var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
}

/// What is recorded.
public enum RecordingSource: Sendable, Equatable {
    case display(CGDirectDisplayID)
    /// A rectangle in the display's point coordinates (origin top-left).
    case region(CGRect, display: CGDirectDisplayID)
    case window(CGWindowID)
}

public struct RecordingConfiguration: Sendable, Equatable {
    public var frameRate = FrameRate.fps60
    public var codec = VideoCodec.hevc
    public var quality = VideoQuality.high
    /// 10-bit 4:2:2 (HEVC only): colored text and thin colored lines stay sharper. Fewer players can decode it.
    public var sharpColor = false
    public var scale = ResolutionScale.native
    public var timing = FrameTiming.variable
    public var showsCursor = true
    public var capturesSystemAudio = true
    public var excludesOwnAudio = true
    public var capturesMicrophone = false
    /// An `AVCaptureDevice.uniqueID`; nil or unknown means the system's default microphone.
    public var microphoneID: String?
    /// Bits per second for each AAC audio track.
    public var audioBitrate = 160_000

    public init() {}
}

/// Turns a configuration and a picture size into what `AVAssetWriter` needs.
public enum EncoderSettings {
    /// Hardware H.264 stops at 4096 pixels on a side; anything larger is encoded as HEVC.
    public static func effectiveCodec(_ codec: VideoCodec, width: Int, height: Int) -> VideoCodec {
        codec == .h264 && (width > 4096 || height > 4096) ? .hevc : codec
    }

    /// Video encoders work on even sizes. Rounds *down*, so the capture rectangle can shrink to match and nothing is resampled.
    public static func evenSize(width: Double, height: Double) -> (width: Int, height: Int) {
        (max(2, Int(width.rounded(.down)) & ~1), max(2, Int(height.rounded(.down)) & ~1))
    }

    public static var colorProperties: [String: String] {
        [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
         AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
         AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
    }

    public static func video(_ configuration: RecordingConfiguration, width: Int, height: Int) -> [String: Any] {
        let codec = effectiveCodec(configuration.codec, width: width, height: height)
        var settings: [String: Any] = [
            AVVideoCodecKey: codec.avType, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: colorProperties,
        ]
        guard !codec.isProRes else { return settings }          // ProRes has one fixed quality
        var compression: [String: Any] = [
            kVTCompressionPropertyKey_Quality as String: configuration.quality.factor,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,           // seekable and trimmable every two seconds
            AVVideoExpectedSourceFrameRateKey: configuration.frameRate.rawValue,
        ]
        if codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        } else if configuration.sharpColor {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main42210_AutoLevel as String
        }
        settings[AVVideoCompressionPropertiesKey] = compression
        return settings
    }

    public static func audio(bitrate: Int, channels: Int = 2, sampleRate: Double = 48_000) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
         AVEncoderBitRateKey: channels == 1 ? min(bitrate, 128_000) : bitrate]
    }
}
