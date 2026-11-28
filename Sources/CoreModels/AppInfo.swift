import Foundation

/// The app's name and version, read from the app bundle's Info.plist (the single place the version number lives).
public enum AppInfo {
    /// Used when the code runs outside the app bundle (tests, `swift run`). Kept equal to `Packaging/Info.plist`, which a test checks.
    public static let fallbackVersion = "0.2.0"

    /// For example "0.2.0".
    public static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? fallbackVersion
    }

    /// For example "v0.2.0".
    public static var displayVersion: String { "v\(version)" }

    /// For example "CaptureDeck v0.2.0".
    public static var nameAndVersion: String { "CaptureDeck \(displayVersion)" }
}
