import Carbon.HIToolbox
import CoreModels

public enum HotkeyError: Error, Equatable {
    /// Another app (or macOS) already owns this combination.
    case alreadyInUse
    case registrationFailed(Int32)
}

/// Global hotkeys via `RegisterEventHotKey`. This needs no Input Monitoring permission
/// and never observes other keystrokes.
@MainActor
public final class HotkeyManager {
    private struct Entry {
        let ref: EventHotKeyRef
        let handler: @MainActor () -> Void
    }

    private var entries: [UInt32: Entry] = [:]
    private var idsByName: [String: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private static let signature: OSType = 0x4344_4B59  // 'CDKY'

    public init() {}

    isolated deinit {
        for entry in entries.values { UnregisterEventHotKey(entry.ref) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// Registers (or re-registers) the hotkey for `name`.
    public func register(name: String, shortcut: KeyShortcut, handler: @escaping @MainActor () -> Void) throws {
        unregister(name: name)
        installEventHandlerIfNeeded()

        let id = nextID
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            Self.carbonModifiers(shortcut.modifiers),
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == OSStatus(eventHotKeyExistsErr) { throw HotkeyError.alreadyInUse }
        guard status == noErr, let ref else { throw HotkeyError.registrationFailed(status) }

        nextID += 1
        entries[id] = Entry(ref: ref, handler: handler)
        idsByName[name] = id
    }

    public func unregister(name: String) {
        guard let id = idsByName.removeValue(forKey: name), let entry = entries.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(entry.ref)
    }

    func fire(id: UInt32) {
        entries[id]?.handler()
    }

    static func carbonModifiers(_ modifiers: KeyShortcut.Modifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers hotkey events on the main thread.
            MainActor.assumeIsolated { manager.fire(id: hotKeyID.id) }
            return noErr
        }, 1, &spec, userData, &eventHandler)
    }
}
