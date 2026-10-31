// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InkBridge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "InkBridge", targets: ["InkBridge"]),
        .executable(name: "inkbridge-probe", targets: ["InkBridgeProbe"]),
        .library(name: "InkBridgeCore", targets: ["InkBridgeCore"]),
    ],
    targets: [
        // Platform logic with no UI: protocol, transport, drawing model, sessions.
        // Everything here is unit-testable without a window server.
        .target(name: "InkBridgeCore", path: "Sources/InkBridgeCore"),

        // The menu-bar app: overlay windows, toolbar, hotkeys.
        .executableTarget(
            name: "InkBridge",
            dependencies: ["InkBridgeCore"],
            path: "Sources/InkBridge"
        ),

        // Headless receiver used for end-to-end and latency measurements.
        .executableTarget(
            name: "InkBridgeProbe",
            dependencies: ["InkBridgeCore"],
            path: "Sources/InkBridgeProbe"
        ),

        .testTarget(
            name: "InkBridgeCoreTests",
            dependencies: ["InkBridgeCore"],
            path: "Tests/InkBridgeCoreTests"
        ),
    ]
)
