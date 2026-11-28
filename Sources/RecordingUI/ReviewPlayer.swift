import AVFoundation
import Combine

/// Plays the recording under review and tells the timeline where the playhead is.
@MainActor
public final class ReviewPlayer: ObservableObject {
    public let player: AVPlayer
    @Published public private(set) var time = 0.0
    @Published public private(set) var isPlaying = false
    @Published public var isMuted = false { didSet { player.isMuted = isMuted } }
    private let url: URL
    private var timeObserver: Any?
    private var rate: AnyCancellable?
    private var seeking = false
    private var wanted: Double?

    public init(url: URL) {
        self.url = url
        player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] now in
            MainActor.assumeIsolated {
                guard let self, !self.seeking, self.player.rate != 0 else { return }
                self.time = max(0, now.seconds)
            }
        }
        rate = player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main)
            .sink { [weak self] status in MainActor.assumeIsolated { self?.isPlaying = status != .paused } }
    }

    /// Plays or pauses. Playing stays inside the part that will be saved.
    public func toggle(start: Double, end: Double) {
        if isPlaying { pause(); return }
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
        if time < start - 0.01 || time >= end - 0.05 { seek(start) }
        player.play()
    }

    public func pause() { player.pause() }

    /// Moves to exactly `seconds`. While a handle is dragged, requests arrive faster than frames can be shown: only the
    /// latest one is kept waiting.
    public func seek(_ seconds: Double) {
        time = max(0, seconds)
        wanted = time
        if !seeking { runSeek() }
    }

    private func runSeek() {
        guard let target = wanted else { return }
        wanted = nil
        seeking = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self else { return }
                self.seeking = false
                if self.wanted != nil { self.runSeek() }
            } }
        }
    }

    /// Lets go of the file (before it is moved or deleted), or takes it up again.
    public func unload() {
        pause()
        player.replaceCurrentItem(with: nil)
    }

    public func reload() { player.replaceCurrentItem(with: AVPlayerItem(url: url)) }
}
