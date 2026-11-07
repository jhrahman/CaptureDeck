// swift-tools-version: 6.0
import PackageDescription

// Dependencies point downward only:
//   CaptureDeck (app) -> CaptureEngine, Platform, DesignSystem -> CoreModels
let package = Package(
    name: "CaptureDeck",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CaptureDeck", targets: ["CaptureDeck"]),
    ],
    targets: [
        // Pure value types and protocols shared by every module. No UI, no frameworks beyond CoreGraphics.
        .target(name: "CoreModels"),
        // UI tokens and theming.
        .target(name: "DesignSystem"),
        // Getting pixels: ScreenGrabber, capture modes. Never imports SwiftUI.
        .target(name: "CaptureEngine", dependencies: ["CoreModels"]),
        // System services: permissions, clipboard, global hotkeys.
        .target(name: "Platform", dependencies: ["CoreModels"]),
        // App shell and composition root.
        .executableTarget(
            name: "CaptureDeck",
            dependencies: ["CoreModels", "CaptureEngine", "Platform", "DesignSystem"]
        ),
        .testTarget(name: "CoreModelsTests", dependencies: ["CoreModels"]),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
        .testTarget(name: "CaptureEngineTests", dependencies: ["CaptureEngine", "CoreModels"]),
        .testTarget(name: "PlatformTests", dependencies: ["Platform", "CoreModels"]),
    ]
)
