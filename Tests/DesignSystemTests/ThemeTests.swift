import AppKit
import Testing
@testable import DesignSystem

@MainActor
struct ThemeTests {
    private func hex(of color: NSColor, appearance: NSAppearance.Name) -> UInt32 {
        var result: UInt32 = 0
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            let r = UInt32((c.redComponent * 255).rounded())
            let g = UInt32((c.greenComponent * 255).rounded())
            let b = UInt32((c.blueComponent * 255).rounded())
            result = (r << 16) | (g << 8) | b
        }
        return result
    }

    @Test func tokensResolvePerAppearance() {
        #expect(hex(of: Theme.windowBackground, appearance: .darkAqua) == 0x17191B)
        #expect(hex(of: Theme.windowBackground, appearance: .aqua) == 0xF4F1EA)
        #expect(hex(of: Theme.accent, appearance: .darkAqua) == 0xFFC93C)
        #expect(hex(of: Theme.accent, appearance: .aqua) == 0xE0A100)
    }

    @Test func preferenceMapsToAppearance() {
        #expect(AppearancePreference.system.appearance == nil)
        #expect(AppearancePreference.darkAsh.appearance?.name == .darkAqua)
        #expect(AppearancePreference.light.appearance?.name == .aqua)
    }

    @Test func controllerDefaultsToSystemAndPersists() {
        let suite = "CaptureDeckTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let controller = AppearanceController(defaults: defaults)
        #expect(controller.preference == .system)

        controller.set(.darkAsh)
        #expect(AppearanceController(defaults: defaults).preference == .darkAsh)
    }

    @Test func controllerIgnoresUnknownStoredValue() {
        let suite = "CaptureDeckTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("nonsense", forKey: AppearanceController.defaultsKey)
        #expect(AppearanceController(defaults: defaults).preference == .system)
    }
}
