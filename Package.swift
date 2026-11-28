// swift-tools-version: 6.0
import PackageDescription

// Dependencies point downward only:
//   CaptureDeck (app) -> EditorUI -> EditorEngine -> CoreModels
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
        // Screen recording: capture, microphone, movie writing and export. No UI.
        .target(name: "RecordingEngine"),
        // Recording controls, click and key highlights, and the review window.
        .target(name: "RecordingUI", dependencies: ["RecordingEngine", "DesignSystem"]),
        // System services: permissions, clipboard, global hotkeys.
        .target(name: "Platform", dependencies: ["CoreModels"]),
        // Settings registry and typed store: the only code that touches UserDefaults. Features read values through it.
        .target(name: "Settings", dependencies: ["CoreModels"]),
        // The tabbed Settings window, generated from the registry.
        .target(name: "SettingsUI", dependencies: ["Settings", "CoreModels", "DesignSystem", "Platform"]),
        // Editor document model, image operations, commands (undo/redo). No UI.
        .target(name: "EditorEngine", dependencies: ["CoreModels"]),
        // Editor windows, tabs, canvas, menus (AppKit).
        .target(name: "EditorUI", dependencies: ["EditorEngine", "CoreModels", "DesignSystem", "Platform", "Settings"]),
        // App shell and composition root.
        .executableTarget(
            name: "CaptureDeck",
            dependencies: ["CoreModels", "CaptureEngine", "Platform", "DesignSystem", "EditorUI", "Settings", "SettingsUI", "RecordingEngine", "RecordingUI"]
        ),
        .testTarget(name: "CoreModelsTests", dependencies: ["CoreModels"]),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
        .testTarget(name: "CaptureEngineTests", dependencies: ["CaptureEngine", "CoreModels"]),
        .testTarget(name: "SettingsTests", dependencies: ["Settings", "CoreModels"]),
        .testTarget(name: "EditorUITests", dependencies: ["EditorUI", "EditorEngine", "CoreModels"]),
        .testTarget(name: "EditorEngineTests", dependencies: ["EditorEngine", "CoreModels"]),
        .testTarget(name: "PlatformTests", dependencies: ["Platform", "CoreModels"]),
        .testTarget(name: "RecordingEngineTests", dependencies: ["RecordingEngine"]),
        .testTarget(name: "RecordingUITests", dependencies: ["RecordingUI", "RecordingEngine"]),
    ]
)
