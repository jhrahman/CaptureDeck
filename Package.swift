// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CaptureDeck",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CaptureDeck", targets: ["CaptureDeck"]),
    ],
    targets: [
        // Pure UI tokens and theming. No capture or editor logic.
        .target(name: "DesignSystem"),
        // App shell: lifecycle, menu bar. Composition root.
        .executableTarget(name: "CaptureDeck", dependencies: ["DesignSystem"]),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
    ]
)
