import ServiceManagement

/// "Start CaptureDeck when I log in", through the system's Login Items.
public enum LoginItem {
    public enum Status: Equatable, Sendable {
        case enabled
        case disabled
        /// Registered, but the user still has to switch it on in System Settings > General > Login Items.
        case requiresApproval
        /// The app is not in a place macOS can register it from (for example, not an app bundle).
        case unavailable
    }

    static func status(from system: SMAppService.Status) -> Status {
        switch system {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    public static var status: Status { status(from: SMAppService.mainApp.status) }

    /// Turns "open at login" on or off. Throws if macOS refuses.
    public static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled { try service.register() }
        } else if service.status != .notRegistered {
            try service.unregister()
        }
    }

    /// A sentence for the user when the item is not simply on or off.
    public static func explanation(for status: Status) -> String? {
        switch status {
        case .requiresApproval: "Turn CaptureDeck on in System Settings > General > Login Items & Extensions."
        case .unavailable: "macOS cannot register this copy of CaptureDeck. Move it to the Applications folder and try again."
        default: nil
        }
    }
}
