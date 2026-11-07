import CoreModels
import Foundation

/// A stored setting value. Every setting has exactly one of these types.
public enum SettingValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    /// `nil` = no shortcut assigned.
    case shortcut(KeyShortcut?)

    /// What goes into UserDefaults.
    var stored: Any {
        switch self {
        case .bool(let v): v
        case .int(let v): v
        case .double(let v): v
        case .string(let v): v
        case .shortcut(let v):
            v.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }

    /// Reads a stored value back, interpreting it as the same type as `template` (the default).
    /// Returns nil if the stored object has the wrong type.
    static func decode(_ object: Any?, like template: SettingValue) -> SettingValue? {
        guard let object else { return nil }
        switch template {
        case .bool: return (object as? Bool).map(SettingValue.bool)
        case .int: return (object as? Int).map(SettingValue.int)
        case .double: return (object as? Double).map(SettingValue.double)
        case .string: return (object as? String).map(SettingValue.string)
        case .shortcut:
            guard let text = object as? String else { return nil }
            if text.isEmpty { return .shortcut(nil) }
            guard let shortcut = try? JSONDecoder().decode(KeyShortcut.self, from: Data(text.utf8)) else { return nil }
            return .shortcut(shortcut)
        }
    }
}
