import Foundation

/// Which wheel direction scrolls toward the end of the content, learned from what actually happened and remembered, so the
/// next capture starts in the right direction instead of guessing.
///
/// Which way a synthetic wheel value moves the content depends on how the event is delivered and on the user's
/// "Natural scrolling" setting, so the default is only a first guess; every capture checks it against the real result.
struct ScrollDirectionMemory {
    private let defaults: UserDefaults
    private func key(_ axis: ScrollStitcher.Axis) -> String { "scrolling.towardEnd.\(axis == .vertical ? "vertical" : "horizontal")" }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The wheel method that moves toward the end of the content on this Mac.
    func towardEnd(_ axis: ScrollStitcher.Axis) -> ScrollMethod {
        switch defaults.string(forKey: key(axis)) {
        case "wheel": return .wheel
        case "wheelReversed": return .wheelReversed
        default:
            // First guess. The wheel events are sent as a trackpad-style gesture, which macOS treats as already adjusted for the
            // Natural scrolling setting, so a negative value moves toward the end. Every capture still verifies this.
            return .wheel
        }
    }

    func learn(_ axis: ScrollStitcher.Axis, towardEnd method: ScrollMethod) {
        switch method {
        case .wheel: defaults.set("wheel", forKey: key(axis))
        case .wheelReversed: defaults.set("wheelReversed", forKey: key(axis))
        case .pageKey, .homeKey: break
        }
    }

    static func opposite(of method: ScrollMethod) -> ScrollMethod {
        switch method {
        case .wheel: return .wheelReversed
        case .wheelReversed: return .wheel
        case .pageKey, .homeKey: return method
        }
    }
}
