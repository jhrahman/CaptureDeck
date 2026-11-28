import CoreMedia

/// Maps the capture clock (host time, shared by video, system audio and microphone) onto the movie's own time, which starts
/// at zero and skips everything that happened while paused. Pure arithmetic, so audio and video cannot drift apart.
struct RecordingTimeline {
    private(set) var start: CMTime?
    /// Paused stretches in capture time; the last one has no end while paused.
    private var pauses: [(from: CMTime, to: CMTime?)] = []

    var isPaused: Bool { pauses.last.map { $0.to == nil } ?? false }

    mutating func begin(at time: CMTime) { if start == nil { start = time } }

    mutating func pause(at time: CMTime) {
        guard !isPaused else { return }
        pauses.append((time, nil))
    }

    mutating func resume(at time: CMTime) {
        guard isPaused else { return }
        pauses[pauses.count - 1].to = time
    }

    /// Where something captured at `time` belongs in the movie, or nil if it must be left out (before the start, or while
    /// paused). A sample is judged by when it was captured, so one that arrives late still lands in the right place.
    func movieTime(for time: CMTime) -> CMTime? {
        guard let start, time >= start else { return nil }
        var skipped = CMTime.zero
        for pause in pauses {
            guard time >= pause.from else { continue }
            guard let to = pause.to, time >= to else { return nil }                 // captured during this pause
            let from = CMTimeMaximum(pause.from, start)
            if to > from { skipped = skipped + (to - from) }
        }
        return time - start - skipped
    }

    /// The movie's length if it ended at `time`.
    func duration(at time: CMTime) -> CMTime {
        if let pause = pauses.last, pause.to == nil { return movieTime(for: pause.from - CMTime(value: 1, timescale: 1_000_000)) ?? .zero }
        return movieTime(for: time) ?? .zero
    }
}
