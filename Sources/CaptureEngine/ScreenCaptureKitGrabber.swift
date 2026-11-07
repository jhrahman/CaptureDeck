import CoreGraphics
import CoreImage
import CoreMedia
import CoreModels
import ScreenCaptureKit

/// `ScreenGrabber` backed by ScreenCaptureKit.
/// macOS 14+ uses `SCScreenshotManager`; macOS 13 grabs a single frame from an `SCStream`.
public struct ScreenCaptureKitGrabber: ScreenGrabber {
    public init() {}

    public func capture(_ target: CaptureTarget, includeCursor: Bool) async throws -> CapturedImage {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            // Without Screen Recording permission this call fails.
            throw CaptureError.permissionDenied
        }

        let displayID: CGDirectDisplayID
        switch target {
        case .display(let id), .rect(_, let id): displayID = id
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplayAvailable
        }

        let scale = Self.scale(of: display)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = includeCursor
        configuration.capturesAudio = false

        let pointSize: CGSize
        switch target {
        case .display:
            pointSize = CGSize(width: display.width, height: display.height)
        case .rect(let rect, _):
            configuration.sourceRect = rect
            pointSize = rect.size
        }
        let pixels = pixelDimensions(pointSize: pointSize, scale: scale)
        configuration.width = pixels.width
        configuration.height = pixels.height

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let image = try await Self.grab(filter: filter, configuration: configuration)
        return CapturedImage(cgImage: image, scale: scale)
    }

    private static func scale(of display: SCDisplay) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(display.displayID), mode.width > 0 else { return 1 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }

    private static func grab(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        do {
            if #available(macOS 14.0, *) {
                return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            } else {
                return try await SingleFrameCapture.grab(filter: filter, configuration: configuration)
            }
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.captureFailed(error.localizedDescription)
        }
    }
}

/// `SCStream` is only used from the single-frame helper below, one call at a time.
private struct StreamBox: @unchecked Sendable {
    let value: SCStream
    init(_ value: SCStream) { self.value = value }
}

/// macOS 13 fallback: run an `SCStream` just long enough to receive one complete frame.
private final class SingleFrameCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage, any Error>?
    private let ciContext = CIContext()

    static func grab(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        let capture = SingleFrameCapture()
        let stream = StreamBox(SCStream(filter: filter, configuration: configuration, delegate: nil))
        try stream.value.addStreamOutput(capture, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capturedeck.singleframe"))

        let image: CGImage
        do {
            image = try await withCheckedThrowingContinuation { continuation in
                capture.setContinuation(continuation)
                Task {
                    do { try await stream.value.startCapture() } catch { capture.finish(.failure(error)) }
                }
                // Give up if no frame arrives.
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    capture.finish(.failure(CaptureError.captureFailed("Timed out waiting for a frame")))
                }
            }
        } catch {
            try? await stream.value.stopCapture()
            throw error
        }
        try? await stream.value.stopCapture()
        return image
    }

    private func setContinuation(_ c: CheckedContinuation<CGImage, any Error>) {
        lock.lock(); continuation = c; lock.unlock()
    }

    /// Resumes the continuation exactly once.
    private func finish(_ result: Result<CGImage, any Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
            finish(.success(cgImage))
        }
    }
}
