import AVFoundation
import CoreGraphics
import Testing
import VideoToolbox
@testable import RecordingEngine

private func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000) }

struct RecordingTimelineTests {
    @Test func theMovieStartsAtZeroAndLeavesOutPauses() {
        var line = RecordingTimeline()
        #expect(line.movieTime(for: t(100)) == nil)                       // not started
        line.begin(at: t(100))
        #expect(line.movieTime(for: t(99.9)) == nil)
        #expect(line.movieTime(for: t(102))?.seconds == 2)
        line.pause(at: t(103))
        #expect(line.isPaused)
        #expect(line.movieTime(for: t(104)) == nil)
        #expect(abs(line.duration(at: t(109)).seconds - 3) < 0.001)       // stopped while paused
        line.resume(at: t(110))
        #expect(abs(line.movieTime(for: t(111))!.seconds - 4) < 0.001)
    }

    /// Audio often arrives after the user has pressed pause or resume: it belongs where it was captured.
    @Test func lateSamplesAreJudgedByWhenTheyWereCaptured() {
        var line = RecordingTimeline()
        line.begin(at: t(10))
        line.pause(at: t(12))
        line.resume(at: t(20))
        #expect(line.movieTime(for: t(11.5))?.seconds == 1.5)
        #expect(line.movieTime(for: t(15)) == nil)
    }
}

struct CaptureGeometryTests {
    @Test func sizesAreEvenAndTheCapturedRectangleMatchesThemExactly() {
        for scale in [CGFloat(1), 2] {
            for rect in [CGRect(x: 10.3, y: 7.8, width: 641.5, height: 481), CGRect(x: 0, y: 0, width: 1920, height: 1080)] {
                let g = CaptureGeometry.make(rect: rect, scale: scale)
                #expect(g.width % 2 == 0 && g.height % 2 == 0)
                #expect(g.sourceRect.width * scale == CGFloat(g.width) && g.sourceRect.height * scale == CGFloat(g.height))     // no resampling
                #expect((g.sourceRect.minX * scale).rounded() == g.sourceRect.minX * scale)                                    // on the pixel grid
                #expect(abs(CGFloat(g.width) - rect.width * scale) <= 2)
            }
        }
    }
}

struct EncoderSettingsTests {
    @Test func h264IsReplacedByHEVCBeyondItsSizeLimit() {
        #expect(EncoderSettings.effectiveCodec(.h264, width: 3840, height: 2160) == .h264)
        #expect(EncoderSettings.effectiveCodec(.h264, width: 5120, height: 2880) == .hevc)
    }

    @Test func qualityAndProfileReachTheEncoder() {
        var c = RecordingConfiguration()
        c.sharpColor = true
        c.quality = .maximum
        let compression = EncoderSettings.video(c, width: 100, height: 100)[AVVideoCompressionPropertiesKey] as? [String: Any]
        #expect(compression?[kVTCompressionPropertyKey_Quality as String] as? Double == 0.85)
        #expect(compression?[AVVideoProfileLevelKey] as? String == kVTProfileLevel_HEVC_Main42210_AutoLevel as String)
        c.codec = .proRes422
        #expect(EncoderSettings.video(c, width: 100, height: 100)[AVVideoCompressionPropertiesKey] == nil)
    }

    @Test func mp4IsNotOfferedForProRes() {
        #expect(ExportFormat.available(for: .proRes422) == [.mov, .gif])
        #expect(ExportFormat.available(for: .hevc) == [.mp4, .mov, .gif])
    }

    @Test func fileSizesReadInKBMBAndGB() {
        #expect(FileSizeText.text(812_000) == "812 KB")
        #expect(FileSizeText.text(24_600_000) == "24.6 MB")
        #expect(FileSizeText.text(1_320_000_000) == "1.32 GB")
    }
}
