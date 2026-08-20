// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NetworkModeGuard",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "NetworkModeGuard", targets: ["NetworkModeGuard"]),
    ],
    targets: [
        .executableTarget(name: "NetworkModeGuard"),
        .testTarget(name: "NetworkModeGuardTests", dependencies: ["NetworkModeGuard"]),
    ]
)
