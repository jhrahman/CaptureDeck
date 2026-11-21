import Foundation
import Testing
@testable import CoreModels

struct AppInfoTests {
    @Test func theVersionIsShownWithAVAndNameAndVersionCombine() {
        #expect(AppInfo.displayVersion == "v\(AppInfo.version)")
        #expect(AppInfo.nameAndVersion == "CaptureDeck v\(AppInfo.version)")
    }

    @Test func theFallbackVersionMatchesTheAppBundlesInfoPlist() throws {
        // Packaging/Info.plist is what ends up in the app; the fallback used outside the bundle must not drift from it.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Packaging/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleShortVersionString"] as? String == AppInfo.fallbackVersion)
    }

    @Test func theVersionLooksLikeASemanticVersion() {
        let parts = AppInfo.version.split(separator: ".")
        #expect(parts.count == 3 && parts.allSatisfy { Int($0) != nil })
    }
}
