// swift-tools-version: 6.2
import PackageDescription

// Kept apart from ArchipelKit so the pure modules build and test without the
// Ghostty toolchain. Run scripts/build-ghostty.sh once before resolving this.
let package = Package(
    name: "TerminalKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "TerminalKit", targets: ["TerminalKit"]),
        .executable(name: "terminal-demo", targets: ["terminal-demo"]),
    ],
    targets: [
        .binaryTarget(name: "GhosttyKit", path: "Frameworks/GhosttyKit.xcframework"),
        .target(
            name: "TerminalKit",
            dependencies: ["GhosttyKit"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
            ]
        ),
        // Manual verification harness; see Sources/terminal-demo/main.swift for flags.
        .executableTarget(
            name: "terminal-demo",
            dependencies: ["TerminalKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
