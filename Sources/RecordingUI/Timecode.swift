import Foundation

/// Times as they are shown and typed: "1:05.25", or "1:02:03.50" from an hour on.
public enum Timecode {
    public static func text(_ seconds: Double) -> String {
        let hundredths = Int((max(0, seconds) * 100).rounded())
        let (h, m, s, f) = (hundredths / 360_000, hundredths / 6000 % 60, hundredths / 100 % 60, hundredths % 100)
        return h > 0 ? String(format: "%d:%02d:%02d.%02d", h, m, s, f) : String(format: "%d:%02d.%02d", m, s, f)
    }

    /// Reads "90", "90.5", "1:30", "01:30.25" or "1:02:03". With colons, minutes and seconds must be below 60.
    /// A comma works as the decimal point. Nil for anything else.
    public static func seconds(from text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            let last = index == parts.count - 1
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber || ($0 == "." && last) }), part.contains(where: \.isNumber),
                  let value = Double(part) else { return nil }
            if index > 0, value >= 60 { return nil }
            total = total * 60 + value
        }
        return total
    }
}

/// Where things are on the trim timeline.
struct TimelineGeometry {
    let width: CGFloat
    let duration: Double
    /// Room at both ends, so the handles can be grabbed at the very start and end.
    static let inset: CGFloat = 12

    private var track: CGFloat { max(width - 2 * Self.inset, 1) }
    func x(_ time: Double) -> CGFloat { Self.inset + track * CGFloat(min(max(time / max(duration, 0.001), 0), 1)) }
    func time(_ x: CGFloat) -> Double { Double(min(max((x - Self.inset) / track, 0), 1)) * duration }

    enum Target: Equatable { case start, end, playhead }

    /// What a press at `x` takes hold of. The handles hang outside the kept part, so they stay apart even when it is short.
    func target(at x: CGFloat, start: Double, end: Double) -> Target {
        let startX = self.x(start), endX = self.x(end)
        if x >= startX - 16, x <= startX + 5 { return .start }
        if x >= endX - 5, x <= endX + 16 { return .end }
        return .playhead
    }
}
