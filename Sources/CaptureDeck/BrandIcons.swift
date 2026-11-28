import AppKit

/// The brand's menu bar icons (from CaptureDeck-brand-assets/menubar, copied into the app by the build script).
enum MenuBarIcon: Equatable {
    case idle, recording, paused

    /// The image's name in the app bundle. The recording icon keeps its red dot, so it cannot be tinted by macOS and comes
    /// in two versions: white for a dark menu bar and black for a light one.
    func resourceName(darkMenuBar: Bool) -> String {
        switch self {
        case .idle: "MenuBarIdle"
        case .paused: "MenuBarPaused"
        case .recording: darkMenuBar ? "MenuBarRecordingDark" : "MenuBarRecordingLight"
        }
    }

    var isTemplate: Bool { self != .recording }

    private var label: String {
        switch self {
        case .idle: "CaptureDeck"
        case .recording: "CaptureDeck, recording"
        case .paused: "CaptureDeck, recording paused"
        }
    }

    /// An SF Symbol stands in when run outside a bundle (`swift run`).
    private var fallbackSymbol: String {
        switch self {
        case .idle: "camera.viewfinder"
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        }
    }

    /// The brand artwork at menu bar size, or nil outside the app bundle.
    func bundledImage(darkMenuBar: Bool) -> NSImage? {
        guard let image = NSImage(named: resourceName(darkMenuBar: darkMenuBar))?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    func image(darkMenuBar: Bool) -> NSImage {
        let bundled = NSImage(named: resourceName(darkMenuBar: darkMenuBar))
        let image = (bundled ?? NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: label) ?? NSImage()).copy() as! NSImage
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = bundled == nil || isTemplate
        image.accessibilityDescription = label
        return image
    }
}
