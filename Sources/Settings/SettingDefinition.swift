import Foundation

/// A tab in the Settings window. Adding a new category is just creating a new section.
public struct SettingsSection: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    /// SF Symbol shown on the tab.
    public let symbol: String
    public let order: Int

    public init(id: String, title: String, symbol: String, order: Int) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.order = order
    }

    public static let general = SettingsSection(id: "general", title: "General", symbol: "gearshape", order: 0)
    public static let capture = SettingsSection(id: "capture", title: "Capture", symbol: "camera.viewfinder", order: 1)
    public static let hotkeys = SettingsSection(id: "hotkeys", title: "Hotkeys", symbol: "keyboard", order: 2)
    public static let panel = SettingsSection(id: "panel", title: "Capture Panel", symbol: "rectangle.3.group", order: 3)
    public static let editor = SettingsSection(id: "editor", title: "Editor", symbol: "slider.horizontal.3", order: 4)
    public static let output = SettingsSection(id: "output", title: "Output", symbol: "square.and.arrow.down", order: 5)
    public static let appearance = SettingsSection(id: "appearance", title: "Appearance", symbol: "paintbrush", order: 6)
    public static let advanced = SettingsSection(id: "advanced", title: "Advanced", symbol: "wrench.and.screwdriver", order: 7)
}

/// Everything the app knows about one setting. The Settings window, validation, reset and
/// migration are all generated from these, so a new option is one definition.
public struct SettingDefinition: Sendable, Identifiable {
    public struct Choice: Sendable, Hashable {
        public let value: String
        public let title: String
        public init(_ value: String, _ title: String) {
            self.value = value
            self.title = title
        }
    }

    public enum Control: Sendable {
        case toggle
        case stepper(ClosedRange<Int>, unit: String?)
        case slider(ClosedRange<Double>, step: Double)
        case choice([Choice])
        case text(placeholder: String?)
        case folder
        case shortcut
        /// A comma-separated list of pixel sizes, e.g. "640x480, 1280x720".
        case sizeList
        /// Stored state that is not shown in the window (last used size, "already asked" flags...).
        case hidden
    }

    /// Stable key (also the UserDefaults key). Never rename one without a migration.
    public let id: String
    public let section: SettingsSection
    /// Optional sub-heading inside the tab.
    public let group: String?
    public let title: String
    public let help: String?
    public let defaultValue: SettingValue
    public let control: Control
    /// Greys this setting out unless the named toggle setting is on.
    public let dependsOn: String?
    /// Order within its group.
    public let order: Int

    public init(
        id: String, section: SettingsSection, group: String? = nil, title: String, help: String? = nil,
        defaultValue: SettingValue, control: Control, dependsOn: String? = nil, order: Int = 0
    ) {
        self.id = id
        self.section = section
        self.group = group
        self.title = title
        self.help = help
        self.defaultValue = defaultValue
        self.control = control
        self.dependsOn = dependsOn
        self.order = order
    }

    public var isVisible: Bool {
        if case .hidden = control { return false }
        return true
    }

    /// Forces a value into what this control allows (clamps numbers, rejects unknown choices).
    public func validated(_ value: SettingValue) -> SettingValue {
        switch (control, value) {
        case (.stepper(let range, _), .int(let v)): return .int(min(max(v, range.lowerBound), range.upperBound))
        case (.slider(let range, _), .double(let v)):
            return .double(v.isNaN ? defaultValue.doubleValue : min(max(v, range.lowerBound), range.upperBound))
        case (.choice(let choices), .string(let v)): return choices.contains { $0.value == v } ? value : defaultValue
        default:
            // Same type as the default is required.
            return value.sameKind(as: defaultValue) ? value : defaultValue
        }
    }
}

extension SettingValue {
    var doubleValue: Double {
        if case .double(let v) = self { return v }
        return 0
    }

    func sameKind(as other: SettingValue) -> Bool {
        switch (self, other) {
        case (.bool, .bool), (.int, .int), (.double, .double), (.string, .string), (.shortcut, .shortcut): true
        default: false
        }
    }
}

/// All definitions, checked for duplicate keys.
public struct SettingsRegistry: Sendable {
    public private(set) var definitions: [SettingDefinition]
    private let byID: [String: SettingDefinition]

    public init(_ definitions: [SettingDefinition]) {
        var seen = [String: SettingDefinition]()
        for definition in definitions {
            precondition(seen[definition.id] == nil, "Duplicate setting id: \(definition.id)")
            seen[definition.id] = definition
        }
        self.definitions = definitions
        self.byID = seen
    }

    public func definition(for id: String) -> SettingDefinition? { byID[id] }

    /// Sections that have at least one visible setting, in tab order.
    public var sections: [SettingsSection] {
        Array(Set(definitions.filter(\.isVisible).map(\.section))).sorted { $0.order < $1.order }
    }

    public func definitions(in section: SettingsSection) -> [SettingDefinition] {
        definitions.filter { $0.section == section && $0.isVisible }
    }
}
