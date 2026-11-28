import Foundation

/// A heading as it is shown above a group of settings.
public struct SettingsHeading: Equatable, Sendable {
    /// What a group name ends with when its settings take effect even in the middle of a recording.
    public static let liveSuffix = " (changes apply while recording)"

    public let title: String
    public let isLive: Bool

    public init(_ group: String) {
        isLive = group.hasSuffix(Self.liveSuffix)
        title = isLive ? String(group.dropLast(Self.liveSuffix.count)) : group
    }
}

/// Finding settings by words, across every page.
public enum SettingsSearch {
    /// Settings whose name, explanation, group, page or choices contain every word of `query`, in page order.
    public static func matches(_ query: String, in registry: SettingsRegistry) -> [SettingDefinition] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return registry.sections.flatMap { section in
            registry.definitions(in: section).filter { definition in
                var parts = [definition.title, definition.help ?? "", definition.group.map { SettingsHeading($0).title } ?? "", section.title]
                if case .choice(let choices) = definition.control { parts += choices.map(\.title) }
                let text = parts.joined(separator: " ")
                return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
    }
}
