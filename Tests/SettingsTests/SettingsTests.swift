import CoreModels
import Foundation
import Testing
@testable import Settings

private let section = SettingsSection.capture

private func registry() -> SettingsRegistry {
    SettingsRegistry([
        SettingDefinition(id: "t.flag", section: section, title: "Flag", defaultValue: .bool(true), control: .toggle),
        SettingDefinition(id: "t.count", section: section, title: "Count", defaultValue: .int(5), control: .stepper(0...10, unit: "s")),
        SettingDefinition(id: "t.level", section: section, title: "Level", defaultValue: .double(0.5), control: .slider(0...1, step: 0.1)),
        SettingDefinition(id: "t.mode", section: .output, title: "Mode", defaultValue: .string("png"),
                          control: .choice([.init("png", "PNG"), .init("jpeg", "JPEG")])),
        SettingDefinition(id: "t.name", section: .output, title: "Name", defaultValue: .string("x"), control: .text(placeholder: nil)),
        SettingDefinition(id: "t.hotkey", section: .hotkeys, title: "Hotkey", defaultValue: .shortcut(.digit(1, [.control, .shift])), control: .shortcut),
        SettingDefinition(id: "t.state", section: .advanced, title: "State", defaultValue: .bool(false), control: .hidden),
    ])
}

private func freshDefaults() -> (UserDefaults, () -> Void) {
    let suite = "CaptureDeckTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (defaults, { defaults.removePersistentDomain(forName: suite) })
}

struct RegistryTests {
    @Test func sectionsListOnlyVisibleSettingsInTabOrder() {
        // "advanced" only has a hidden setting, so it gets no tab.
        #expect(registry().sections.map(\.id) == ["capture", "hotkeys", "output"])
        #expect(registry().definitions(in: .output).map(\.id) == ["t.mode", "t.name"])
    }

    @Test func lookupByID() {
        #expect(registry().definition(for: "t.count")?.title == "Count")
        #expect(registry().definition(for: "nope") == nil)
    }
}

struct ValidationTests {
    private let r = registry()

    @Test func numbersAreClampedAndChoicesChecked() {
        #expect(r.definition(for: "t.count")!.validated(.int(99)) == .int(10))
        #expect(r.definition(for: "t.count")!.validated(.int(-4)) == .int(0))
        #expect(r.definition(for: "t.level")!.validated(.double(7)) == .double(1))
        #expect(r.definition(for: "t.level")!.validated(.double(.nan)) == .double(0.5))
        #expect(r.definition(for: "t.mode")!.validated(.string("webp")) == .string("png"))
        #expect(r.definition(for: "t.mode")!.validated(.string("jpeg")) == .string("jpeg"))
    }

    @Test func wrongTypeFallsBackToDefault() {
        #expect(r.definition(for: "t.flag")!.validated(.int(3)) == .bool(true))
        #expect(r.definition(for: "t.name")!.validated(.bool(false)) == .string("x"))
    }
}

@MainActor
struct StoreTests {
    @Test func startsAtDefaults() {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let store = SettingsStore(registry: registry(), defaults: defaults)
        #expect(store.bool("t.flag") && store.int("t.count") == 5 && store.double("t.level") == 0.5)
        #expect(store.string("t.mode") == "png")
        #expect(store.shortcut("t.hotkey") == .digit(1, [.control, .shift]))
        #expect(store.isDefault("t.count"))
    }

    @Test func valuesPersistAcrossStores() {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let a = SettingsStore(registry: registry(), defaults: defaults)
        a.set(false, for: "t.flag"); a.set(8, for: "t.count"); a.set(0.2, for: "t.level")
        a.set("jpeg", for: "t.mode"); a.set(.digit(7, [.command, .option]), for: "t.hotkey")
        let b = SettingsStore(registry: registry(), defaults: defaults)
        #expect(!b.bool("t.flag") && b.int("t.count") == 8 && b.double("t.level") == 0.2)
        #expect(b.string("t.mode") == "jpeg")
        #expect(b.shortcut("t.hotkey") == .digit(7, [.command, .option]))
        #expect(!b.isDefault("t.count"))
    }

    @Test func clearedShortcutPersistsAsNone() {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let a = SettingsStore(registry: registry(), defaults: defaults)
        a.set(nil as KeyShortcut?, for: "t.hotkey")
        #expect(SettingsStore(registry: registry(), defaults: defaults).shortcut("t.hotkey") == nil)
    }

    @Test func invalidValuesAreCorrectedOnWriteAndOnLoad() {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let store = SettingsStore(registry: registry(), defaults: defaults)
        store.set(500, for: "t.count")
        #expect(store.int("t.count") == 10)
        defaults.set("garbage", forKey: "t.count")          // wrong type in storage
        defaults.set("webp", forKey: "t.mode")              // unknown choice in storage
        let reloaded = SettingsStore(registry: registry(), defaults: defaults)
        #expect(reloaded.int("t.count") == 5 && reloaded.string("t.mode") == "png")
    }

    @Test func changesAreAnnouncedOnlyWhenTheValueActuallyChanges() {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let store = SettingsStore(registry: registry(), defaults: defaults)
        var seen: [String] = []
        let token = store.changes.sink { seen.append($0) }
        store.set(false, for: "t.flag")
        store.set(false, for: "t.flag")      // no change
        store.set(99, for: "t.count")        // clamps to 10: a change
        store.set(99, for: "t.count")        // clamps to 10 again: no change
        token.cancel()
        #expect(seen == ["t.flag", "t.count"])
    }

    @Test func resetRestoresDefaultsPerSettingTabAndEverything() {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let store = SettingsStore(registry: registry(), defaults: defaults)
        store.set(false, for: "t.flag"); store.set(9, for: "t.count"); store.set("jpeg", for: "t.mode"); store.set(true, for: "t.state")
        store.reset("t.flag")
        #expect(store.bool("t.flag"))
        store.reset(section: .capture)
        #expect(store.int("t.count") == 5 && store.string("t.mode") == "jpeg")   // other tab untouched
        store.resetAll()
        #expect(store.string("t.mode") == "png")
        #expect(store.bool("t.state"))      // hidden state is not reset by the user-facing reset
    }

    @Test func notesCanBeSetAndCleared() {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        let store = SettingsStore(registry: registry(), defaults: defaults)
        store.setNote("In use", for: "t.hotkey")
        #expect(store.notes["t.hotkey"] == "In use")
        store.setNote(nil, for: "t.hotkey")
        #expect(store.notes["t.hotkey"] == nil)
    }
}

struct MigrationTests {
    @Test func oldPermissionFlagsMoveToStateKeysOnce() {
        let (defaults, cleanup) = freshDefaults(); defer { cleanup() }
        defaults.set(true, forKey: "permission.screenRecording.asked")
        SettingsMigration.run(on: defaults)
        #expect(defaults.bool(forKey: "state.screenRecordingAsked"))
        #expect(defaults.object(forKey: "permission.screenRecording.asked") == nil)
        #expect(defaults.integer(forKey: SettingsMigration.schemaVersionKey) == SettingsMigration.currentSchemaVersion)
        SettingsMigration.run(on: defaults)       // safe to run again
        #expect(defaults.bool(forKey: "state.screenRecordingAsked"))
    }
}

struct ShortcutConflictTests {
    private let assigned = [
        ShortcutAssignment(id: "a", title: "Capture Region", shortcut: .digit(2, [.control, .shift])),
        ShortcutAssignment(id: "b", title: "Capture Full Screen", shortcut: .digit(1, [.control, .shift])),
    ]

    @Test func detectsDuplicateInApp() {
        let c = ShortcutConflicts.check(.digit(1, [.control, .shift]), for: "a", among: assigned)
        #expect(c == .sameApp(actionTitle: "Capture Full Screen") && c?.blocksChange == true)
    }

    @Test func ignoresTheActionBeingEdited() {
        #expect(ShortcutConflicts.check(.digit(2, [.control, .shift]), for: "a", among: assigned) == nil)
    }

    @Test func warnsAboutSystemShortcutsWithoutBlocking() {
        let c = ShortcutConflicts.check(.digit(3, [.command, .shift]), for: "a", among: assigned)
        #expect(c == .system(description: "the macOS screenshot shortcut") && c?.blocksChange == false)
        #expect(ShortcutConflicts.check(.digit(9, [.control, .option]), for: "a", among: assigned) == nil)
    }

    @Test func globalShortcutNeedsAModifierOtherThanShift() {
        #expect(!ShortcutConflicts.isUsableAsGlobal(.digit(1, [])))
        #expect(!ShortcutConflicts.isUsableAsGlobal(.digit(1, [.shift])))
        #expect(ShortcutConflicts.isUsableAsGlobal(.digit(1, [.control])))
    }

    @Test func keyLabels() {
        #expect(KeyLabels.label(forKeyCode: 49, typed: " ") == "Space")
        #expect(KeyLabels.label(forKeyCode: 122, typed: nil) == "F1")
        #expect(KeyLabels.label(forKeyCode: 0, typed: "a") == "A")
        #expect(KeyLabels.label(forKeyCode: 999, typed: "") == "Key 999")
    }
}
