import Combine
import CoreModels
import Foundation

/// The single place settings live. Features read values here and subscribe to changes;
/// nothing else in the app touches UserDefaults. Changes apply immediately.
@MainActor
public final class SettingsStore: ObservableObject {
    public let registry: SettingsRegistry
    /// Emits the id of every setting that changes.
    public let changes = PassthroughSubject<String, Never>()
    /// Short messages shown under a setting in the window (e.g. "This shortcut is used by another app").
    @Published public private(set) var notes: [String: String] = [:]

    /// Edits made in the Settings window that have not been applied yet. Features never see these:
    /// they only see saved values, so nothing changes until the user presses Apply.
    @Published public private(set) var pending: [String: SettingValue] = [:]

    private let defaults: UserDefaults
    private var values: [String: SettingValue] = [:]

    public init(registry: SettingsRegistry, defaults: UserDefaults = .standard) {
        self.registry = registry
        self.defaults = defaults
        SettingsMigration.run(on: defaults)
        for definition in registry.definitions {
            let stored = SettingValue.decode(defaults.object(forKey: definition.id), like: definition.defaultValue)
            values[definition.id] = definition.validated(stored ?? definition.defaultValue)
        }
    }

    // MARK: Reading

    public func value(_ id: String) -> SettingValue {
        guard let value = values[id] else {
            assertionFailure("Unknown setting: \(id)")
            return .bool(false)
        }
        return value
    }

    public func bool(_ id: String) -> Bool {
        if case .bool(let v) = value(id) { return v }
        assertionFailure("Setting \(id) is not a Bool")
        return false
    }

    public func int(_ id: String) -> Int {
        if case .int(let v) = value(id) { return v }
        assertionFailure("Setting \(id) is not an Int")
        return 0
    }

    public func double(_ id: String) -> Double {
        if case .double(let v) = value(id) { return v }
        assertionFailure("Setting \(id) is not a Double")
        return 0
    }

    public func string(_ id: String) -> String {
        if case .string(let v) = value(id) { return v }
        assertionFailure("Setting \(id) is not a String")
        return ""
    }

    public func shortcut(_ id: String) -> KeyShortcut? {
        if case .shortcut(let v) = value(id) { return v }
        assertionFailure("Setting \(id) is not a shortcut")
        return nil
    }

    public func isDefault(_ id: String) -> Bool {
        guard let definition = registry.definition(for: id) else { return true }
        return values[id] == definition.defaultValue
    }

    // MARK: Writing

    /// Validates, saves and announces the new value. Setting the same value again does nothing.
    public func set(_ newValue: SettingValue, for id: String) {
        guard let definition = registry.definition(for: id) else {
            assertionFailure("Unknown setting: \(id)")
            return
        }
        let value = definition.validated(newValue)
        guard values[id] != value else { return }
        objectWillChange.send()
        values[id] = value
        defaults.set(value.stored, forKey: id)
        changes.send(id)
    }

    public func set(_ value: Bool, for id: String) { set(.bool(value), for: id) }
    public func set(_ value: Int, for id: String) { set(.int(value), for: id) }
    public func set(_ value: Double, for id: String) { set(.double(value), for: id) }
    public func set(_ value: String, for id: String) { set(.string(value), for: id) }
    public func set(_ value: KeyShortcut?, for id: String) { set(.shortcut(value), for: id) }

    public func reset(_ id: String) {
        guard let definition = registry.definition(for: id) else { return }
        set(definition.defaultValue, for: id)
    }

    /// Resets every visible setting on one tab.
    public func reset(section: SettingsSection) {
        for definition in registry.definitions(in: section) { reset(definition.id) }
    }

    public func resetAll() {
        for definition in registry.definitions where definition.isVisible { reset(definition.id) }
    }

    // MARK: Drafts (staged edits for the Settings window)

    /// What the window should show: the staged edit if there is one, otherwise the saved value.
    public func draft(_ id: String) -> SettingValue { pending[id] ?? value(id) }

    public func draftBool(_ id: String) -> Bool { if case .bool(let v) = draft(id) { return v }; return false }
    public func draftInt(_ id: String) -> Int { if case .int(let v) = draft(id) { return v }; return 0 }
    public func draftDouble(_ id: String) -> Double { if case .double(let v) = draft(id) { return v }; return 0 }
    public func draftString(_ id: String) -> String { if case .string(let v) = draft(id) { return v }; return "" }
    public func draftShortcut(_ id: String) -> KeyShortcut? { if case .shortcut(let v) = draft(id) { return v }; return nil }

    /// Stages an edit. Putting a setting back to its saved value un-stages it.
    public func setDraft(_ newValue: SettingValue, for id: String) {
        guard let definition = registry.definition(for: id) else { return }
        let value = definition.validated(newValue)
        let next: SettingValue? = (value == self.value(id)) ? nil : value
        guard pending[id] != next else { return }
        objectWillChange.send()
        pending[id] = next
    }

    public func setDraft(_ value: Bool, for id: String) { setDraft(.bool(value), for: id) }
    public func setDraft(_ value: Int, for id: String) { setDraft(.int(value), for: id) }
    public func setDraft(_ value: Double, for id: String) { setDraft(.double(value), for: id) }
    public func setDraft(_ value: String, for id: String) { setDraft(.string(value), for: id) }
    public func setDraft(_ value: KeyShortcut?, for id: String) { setDraft(.shortcut(value), for: id) }

    public func isPending(_ id: String) -> Bool { pending[id] != nil }
    public var hasPending: Bool { !pending.isEmpty }

    /// Ids of the staged edits, in the order of the registry.
    public var pendingIDs: [String] { registry.definitions.map(\.id).filter { pending[$0] != nil } }

    public func isDraftDefault(_ id: String) -> Bool {
        guard let definition = registry.definition(for: id) else { return true }
        return draft(id) == definition.defaultValue
    }

    /// Stages the default for one setting / every setting on a tab / every setting.
    public func resetDraft(_ id: String) {
        if let definition = registry.definition(for: id) { setDraft(definition.defaultValue, for: id) }
    }
    public func resetDraft(section: SettingsSection) { registry.definitions(in: section).forEach { resetDraft($0.id) } }
    public func resetDraftAll() { registry.definitions.filter(\.isVisible).forEach { resetDraft($0.id) } }

    /// Saves every staged edit and tells the app about each one. Returns the ids that changed.
    @discardableResult
    public func applyPending() -> [String] {
        let ids = pendingIDs
        let staged = pending
        objectWillChange.send()
        pending = [:]
        for id in ids { if let value = staged[id] { set(value, for: id) } }
        return ids
    }

    /// Throws away every staged edit.
    public func discardPending() {
        guard !pending.isEmpty else { return }
        objectWillChange.send()
        pending = [:]
    }

    // MARK: Notes

    public func setNote(_ text: String?, for id: String) {
        guard notes[id] != text else { return }
        notes[id] = text
    }
}

/// Upgrades settings saved by older versions of the app.
public enum SettingsMigration {
    public static let schemaVersionKey = "settings.schemaVersion"
    public static let currentSchemaVersion = 1

    /// Runs each step once, in order. Steps must be safe to repeat.
    public static func run(on defaults: UserDefaults) {
        let version = defaults.integer(forKey: schemaVersionKey)
        if version < 1 { toVersion1(defaults) }
        defaults.set(currentSchemaVersion, forKey: schemaVersionKey)
    }

    /// Version 1: the "already asked for permission" flags moved to hidden settings with a `state.` prefix.
    private static func toVersion1(_ defaults: UserDefaults) {
        let renamed = [
            "permission.screenRecording.asked": "state.screenRecordingAsked",
            "permission.accessibility.asked": "state.accessibilityAsked",
        ]
        for (old, new) in renamed {
            if let value = defaults.object(forKey: old), defaults.object(forKey: new) == nil {
                defaults.set(value, forKey: new)
            }
            defaults.removeObject(forKey: old)
        }
    }
}
