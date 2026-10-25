// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacMax",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything testable without a UI: collectors, rules, store. Never imports SwiftUI or AppKit.
        .target(name: "MacMaxCore"),
        .executableTarget(name: "MacMax", dependencies: ["MacMaxCore"]),
        // Installed as `macmax`. Named MacMaxCLI because `macmax` collides with `MacMax` on a
        // case-insensitive disk; scripts/bundle.sh renames the binary.
        .executableTarget(name: "MacMaxCLI", dependencies: ["MacMaxCore"]),
        .testTarget(name: "MacMaxCoreTests", dependencies: ["MacMaxCore"], exclude: ["Samples"]),
    ]
)
