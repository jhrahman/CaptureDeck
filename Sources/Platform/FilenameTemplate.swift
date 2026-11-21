import Foundation

/// Builds file names from a template such as `Screenshot $Y-$M-$D at $h.$m.$s`.
///
/// Tokens: `$Y` year, `$M` month, `$D` day, `$h` hour (24h), `$m` minute, `$s` second.
/// A run of `#` is replaced by a sequence number padded to that many digits (`####` -> 0007).
public enum FilenameTemplate {
    public static let defaultTemplate = "Screenshot $Y-$M-$D at $h.$m.$s"

    public static func hasSequence(_ template: String) -> Bool { template.contains("#") }

    public static func render(_ template: String, date: Date, sequence: Int = 1, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
        var out = ""
        var chars = Array(template)[...]
        while let ch = chars.first {
            if ch == "$", chars.count >= 2 {
                let token = chars[chars.startIndex + 1]
                switch token {
                case "Y": out += String(format: "%04d", c.year ?? 0)
                case "M": out += two(c.month)
                case "D": out += two(c.day)
                case "h": out += two(c.hour)
                case "m": out += two(c.minute)
                case "s": out += two(c.second)
                default: out += "$" + String(token)
                }
                chars = chars.dropFirst(2)
            } else if ch == "#" {
                let run = chars.prefix { $0 == "#" }.count
                out += String(format: "%0\(run)d", sequence)
                chars = chars.dropFirst(run)
            } else {
                out.append(ch)
                chars = chars.dropFirst()
            }
        }
        return sanitize(out)
    }

    /// The name for a new capture: the template filled in for `date`. If the template has a counter (`####`), it is the first number
    /// whose file does not exist yet (`exists` is asked about each candidate name, without an extension).
    public static func suggestedName(template: String, date: Date = Date(), exists: (String) -> Bool = { _ in false }) -> String {
        let template = template.isEmpty ? defaultTemplate : template
        guard hasSequence(template) else { return render(template, date: date) }
        var number = 1
        while number < 100_000, exists(render(template, date: date, sequence: number)) { number += 1 }
        return render(template, date: date, sequence: number)
    }

    /// File names cannot contain `/` or `:`, and should not be empty or start with a dot.
    static func sanitize(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        return s.isEmpty ? "Screenshot" : s
    }
}
