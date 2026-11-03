// swift-tools-version: 5.9
import PackageDescription

// Foundation core linked for native adapter compilation; no runtime activation or dev-shell wiring.
let package = Package(
    name: "NativeBridgeCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "NativeBridgeCore", targets: ["NativeBridgeCore"])],
    targets: [
        .target(name: "NativeBridgeCore", path: "BridgeCore"),
        .testTarget(name: "NativeBridgeCoreTests", dependencies: ["NativeBridgeCore"], path: "BridgeCoreTests")
    ]
)
