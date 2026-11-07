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

/// Applies the chosen look app-wide. The choice itself is stored by the Settings store.
@MainActor
public final class AppearanceController {
    public private(set) var preference: AppearancePreference

    public init(preference: AppearancePreference = .system) {
        self.preference = preference
    }

    public func set(_ newValue: AppearancePreference) {
        preference = newValue
        apply()
    }

    /// Applies the current preference to the running application.
    public func apply() {
        NSApp?.appearance = preference.appearance
    }
}
