// swift-tools-version: 5.9
import PackageDescription

// Isolated validation package. Not linked into the Bex application or dev shell.
let package = Package(
    name: "NativeBridgeCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "NativeBridgeCore", targets: ["NativeBridgeCore"])],
    targets: [
        .target(name: "NativeBridgeCore", path: "BridgeCore"),
        .testTarget(name: "NativeBridgeCoreTests", dependencies: ["NativeBridgeCore"], path: "BridgeCoreTests")
    ]
)
