import AppKit

/// How the app chooses its look. `system` follows macOS (live); the others force one theme.
public enum AppearancePreference: String, CaseIterable, Sendable {
    case system
    case darkAsh
    case light

    public var title: String {
        switch self {
        case .system: "System"
        case .darkAsh: "Dark Ash"
        case .light: "Light"
        }
    }

    /// `nil` means "follow the system".
    public var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .darkAsh: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        }
    }
}

/// Stores the user's choice and applies it app-wide.
@MainActor
public final class AppearanceController {
    public static let defaultsKey = "appearance.preference"

    private let defaults: UserDefaults

    public private(set) var preference: AppearancePreference

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.defaultsKey)
        self.preference = stored.flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }

    public func set(_ newValue: AppearancePreference) {
        preference = newValue
        defaults.set(newValue.rawValue, forKey: Self.defaultsKey)
        apply()
    }

    /// Applies the current preference to the running application.
    public func apply() {
        NSApp?.appearance = preference.appearance
    }
}
