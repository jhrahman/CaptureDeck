import AppKit

/// CaptureDeck lives in the menu bar. While any window that needs a full menu bar and Dock icon is open
/// (an editor, the Settings window), the app becomes a regular app; when the last one closes it goes back.
@MainActor
public final class ActivationPolicyManager {
    public static let shared = ActivationPolicyManager()
    private var owners = Set<ObjectIdentifier>()

    private init() {}

    public func retain(_ owner: AnyObject) {
        owners.insert(ObjectIdentifier(owner))
        NSApp.setActivationPolicy(.regular)
    }

    public func release(_ owner: AnyObject) {
        owners.remove(ObjectIdentifier(owner))
        if owners.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
