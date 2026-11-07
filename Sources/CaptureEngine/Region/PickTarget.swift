import ApplicationServices
import CoreGraphics
import CoreModels
import Foundation

/// Something the user can click to capture: a whole window or a UI element inside one.
/// `rect` is in global display coordinates (origin top-left of the primary display).
public struct PickCandidate: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case window(CGWindowID)
        case element
    }
    public let kind: Kind
    public let rect: CGRect

    public init(kind: Kind, rect: CGRect) {
        self.kind = kind
        self.rect = rect
    }
}

/// Finds what is under a point. Candidates are ordered from the innermost element outwards,
/// ending with the window itself.
public protocol PickTargetFinder: Sendable {
    func candidates(at globalPoint: CGPoint) -> [PickCandidate]
}

/// Which candidate is currently highlighted. Up/Down arrows walk outwards/inwards.
struct ObjectPickModel {
    private(set) var candidates: [PickCandidate] = []
    private(set) var index = 0

    var current: PickCandidate? { candidates.indices.contains(index) ? candidates[index] : nil }

    /// Keeps the user's parent/child choice while the pointer stays over the same thing.
    mutating func update(_ new: [PickCandidate]) {
        if new.map(\.rect) != candidates.map(\.rect) { index = 0 }
        candidates = new
    }

    mutating func selectParent() { if index + 1 < candidates.count { index += 1 } }
    mutating func selectChild() { if index > 0 { index -= 1 } }
}

enum WindowHitTester {
    /// `info` is ordered front to back (as `CGWindowListCopyWindowInfo` returns it).
    /// Returns the topmost normal window containing `point`, ignoring `excludedPID` (our own overlay).
    static func topWindow(at point: CGPoint, in info: [[String: Any]], excludingPID: pid_t) -> (id: CGWindowID, pid: pid_t, bounds: CGRect)? {
        for window in info {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pid != excludingPID,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 20, bounds.height >= 20,
                  bounds.contains(point),
                  let number = window[kCGWindowNumber as String] as? Int else { continue }
            return (CGWindowID(number), pid, bounds)
        }
        return nil
    }

    /// Removes zero-size and repeated rectangles and anything equal to the window itself.
    static func cleanChain(_ rects: [CGRect], window: CGRect) -> [CGRect] {
        var result: [CGRect] = []
        for rect in rects where rect.width >= 2 && rect.height >= 2 && rect != window {
            if result.last != rect { result.append(rect) }
        }
        return result
    }
}

/// Real finder: window list for windows, Accessibility API for the elements inside them.
/// Without the Accessibility permission only whole windows are offered.
public struct SystemTargetFinder: PickTargetFinder {
    public init() {}

    public func candidates(at point: CGPoint) -> [PickCandidate] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let window = WindowHitTester.topWindow(at: point, in: info, excludingPID: ProcessInfo.processInfo.processIdentifier) else {
            return []
        }
        var result: [PickCandidate] = []
        if AXIsProcessTrusted() {
            let chain = WindowHitTester.cleanChain(Self.elementFrames(at: point, pid: window.pid), window: window.bounds)
            result += chain.map { PickCandidate(kind: .element, rect: $0) }
        }
        result.append(PickCandidate(kind: .window(window.id), rect: window.bounds))
        return result
    }

    /// Frames of the element under `point` and its ancestors, innermost first (window excluded).
    private static func elementFrames(at point: CGPoint, pid: pid_t) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)   // never hang on an unresponsive app
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &found) == .success, var element = found else {
            return []
        }
        var frames: [CGRect] = []
        for _ in 0..<16 {
            if role(of: element) == "AXWindow" { break }
            if let frame = frame(of: element) { frames.append(frame) }
            guard let parent = parent(of: element) else { break }
            element = parent
        }
        return frames
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXParent" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }
}
