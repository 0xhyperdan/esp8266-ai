// swift-tools-version:5.9
import PackageDescription

// Native menu-bar app that serves the clock's dashboard endpoints. Uses only
// system frameworks (AppKit, Network, Foundation) so there are no dependencies
// to fetch or vendor.
let package = Package(
    name: "AIClockBridge",
    defaultLocalization: "en",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "AIClockBridge",
            path: "Sources/AIClockBridge",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "AIClockBridgeTests",
            dependencies: ["AIClockBridge"],
            path: "Tests/AIClockBridgeTests"
        ),
    ]
)
