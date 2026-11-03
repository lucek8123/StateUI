// swift-tools-version:6.4
import PackageDescription

// The StateUI developer toolchain.
//
// This package is deliberately separate from the root StateUI library package:
// the library stays dependency-free and publishable on its own, while the
// developer tool may use Foundation and the platform's native toolchains.
let package = Package(
    name: "StateUITooling",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "stateui", targets: ["stateui"]),
    ],
    targets: [
        .target(
            name: "StateUITooling",
            path: "Sources/StateUITooling",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .executableTarget(
            name: "stateui",
            dependencies: ["StateUITooling"],
            path: "Sources/stateui",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "StateUIToolingTests",
            dependencies: ["StateUITooling"],
            path: "Tests/StateUIToolingTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
