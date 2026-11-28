import AVFoundation
import AppKit
import RecordingEngine

/// What the review window knows about one finished recording, and the work behind "show the size before saving": the file
/// that will be saved is really made (in a temporary folder) whenever the trim or format changes, so the size shown is
/// that file's size, not a guess. Saving then only moves it.
@MainActor
public final class ReviewModel: ObservableObject {
    public enum SizeState: Equatable {
        case preparing
        case ready(Int64)
        case failed(String)
    }

    @Published public private(set) var size = SizeState.preparing
    @Published public var format: ExportFormat { didSet { if format != oldValue { prepare() } } }
    @Published public private(set) var trimStart = 0.0
    @Published public private(set) var trimEnd: Double
    @Published public var name: String
    /// Cut precisely and leave nothing of the removed footage in the file (re-encodes), or copy the video untouched.
    @Published public var exactTrim: Bool { didSet { if exactTrim != oldValue, isTrimmed { prepare() } } }
    /// How far an exact trim has got, 0...1; nil when that is not what is happening.
    @Published public private(set) var progress: Double?
    /// Small pictures from along the recording, for the timeline.
    @Published public private(set) var thumbnails: [NSImage] = []
    private var thumbnailTask: Task<Void, Never>?
    public let duration: Double
    public let formats: [ExportFormat]
    public let master: URL
    /// "2560 × 1440 · 60 fps · HEVC", and whether anything was lost.
    public let summary: String
    public let warning: String?
    public private(set) var isSaved = false

    private let gifOptions: GIFOptions
    private let audioBitrate: Int
    private let mixesAudio: Bool
    private let workFolder: URL
    private var prepared: URL?
    private var mixed: URL?
    private var task: Task<Void, Never>?
    private var generation = 0

    public init(master: URL, duration: Double, summary: String, warning: String?, name: String, format: ExportFormat,
                formats: [ExportFormat], gifOptions: GIFOptions, mixesAudio: Bool, audioBitrate: Int, workFolder: URL,
                exactTrim: Bool = true) {
        self.exactTrim = exactTrim
        self.master = master
        self.duration = duration
        trimEnd = duration
        self.summary = summary
        self.warning = warning
        self.name = name
        self.formats = formats
        self.format = formats.contains(format) ? format : (formats.first ?? .mov)
        self.gifOptions = gifOptions
        self.mixesAudio = mixesAudio
        self.audioBitrate = audioBitrate
        self.workFolder = workFolder
        prepare()
    }

    public var isTrimmed: Bool { trimStart > 0.01 || trimEnd < duration - 0.01 }
    public var trimmedDuration: Double { trimEnd - trimStart }
    /// The shortest clip trimming can leave.
    static let minimumLength = 0.5

    public func setTrim(start: Double? = nil, end: Double? = nil) {
        var (s, e) = (trimStart, trimEnd)
        let shortest = min(Self.minimumLength, duration)
        if let start { s = min(max(start, 0), e - shortest) }
        if let end { e = max(min(end, duration), s + shortest) }
        guard s != trimStart || e != trimEnd else { return }
        (trimStart, trimEnd) = (max(0, s), e)
        prepare(after: 0.6)                                    // wait for the handle to come to rest
    }

    public func resetTrim() {
        guard isTrimmed else { return }
        (trimStart, trimEnd) = (0, duration)
        prepare()
    }

    private var range: CMTimeRange? {
        isTrimmed ? CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600), end: CMTime(seconds: trimEnd, preferredTimescale: 600)) : nil
    }

    /// Builds the file for the current choices. A newer request replaces one still running.
    func prepare(after delay: Double = 0) {
        task?.cancel()
        generation += 1
        let (generation, format, range) = (generation, format, range)
        size = .preparing
        progress = nil
        let exact = exactTrim
        let previous = task
        task = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            do {
                try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
                var source = master
                if mixesAudio {
                    if let mixed { source = mixed } else {
                        source = try await RecordingExporter.mixingAudio(master, to: workFolder.appendingPathComponent("mixed.mov"), bitrate: audioBitrate)
                        mixed = source
                    }
                }
                let output = workFolder.appendingPathComponent("prepared-\(generation).\(format.fileExtension)")
                switch format {
                case .gif:
                    try await RecordingExporter.gif(source, to: output, options: gifOptions, range: range)
                case .mp4, .mov:
                    let container: MovieContainer = format == .mp4 ? .mp4 : .mov
                    if let range, exact {
                        try await RecordingExporter.exactTrim(source, to: output, container: container, range: range, audioBitrate: audioBitrate) { [weak self] done in
                            Task { @MainActor in
                                guard let self, generation == self.generation, self.size == .preparing else { return }
                                self.progress = done
                            }
                        }
                    } else {
                        try await RecordingExporter.movie(source, to: output, container: container, range: range)
                    }
                }
                guard !Task.isCancelled, generation == self.generation else { try? FileManager.default.removeItem(at: output); return }
                if let prepared { try? FileManager.default.removeItem(at: prepared) }
                prepared = output
                progress = nil
                size = .ready(FileSizeText.size(of: output))
            } catch {
                guard !Task.isCancelled, generation == self.generation else { return }
                size = .failed(error.localizedDescription)
            }
        }
    }

    /// Reads a row of small pictures for the timeline.
    public func loadThumbnails(count: Int = 14) {
        guard thumbnailTask == nil, duration > 0 else { return }
        let (master, duration) = (master, duration)
        thumbnailTask = Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: master))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 200, height: 110)
            var pictures: [NSImage] = []
            for index in 0..<count {
                guard !Task.isCancelled else { return }
                let time = CMTime(seconds: duration * (Double(index) + 0.5) / Double(count), preferredTimescale: 600)
                guard let image = try? await generator.image(at: time).image else { continue }
                pictures.append(NSImage(cgImage: image, size: .zero))
                self?.thumbnails = pictures
            }
        }
    }

    /// Waits for the current preparation (tests, and saving without a window).
    public func waitUntilPrepared() async { await task?.value }

    /// Moves the prepared file to `destination` and removes the recording's temporary files.
    public func save(to destination: URL) throws {
        guard case .ready = size, let prepared else { throw RecordingError.export("The file is not ready yet.") }
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: prepared)          // the user agreed to replace it
        } else {
            try manager.moveItem(at: prepared, to: destination)
        }
        isSaved = true
        cleanUp()
    }

    /// A destination in `folder` that does not replace anything.
    public func freeDestination(in folder: URL) -> URL {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        let stem = base.isEmpty ? "Recording" : base
        var url = folder.appendingPathComponent("\(stem).\(format.fileExtension)")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem) \(number).\(format.fileExtension)")
            number += 1
        }
        return url
    }

    /// Deletes the recording and everything made from it.
    public func discard() { cleanUp() }

    private func cleanUp() {
        thumbnailTask?.cancel()
        task?.cancel()
        generation += 1
        try? FileManager.default.removeItem(at: master)
        try? FileManager.default.removeItem(at: workFolder)
    }
}
