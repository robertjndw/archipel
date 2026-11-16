// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ArchipelKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "ArchipelCore", targets: ["ArchipelCore"]),
        .library(name: "AgentKit", targets: ["AgentKit"]),
        .library(name: "GitKit", targets: ["GitKit"]),
        .library(name: "InspectorUI", targets: ["InspectorUI"]),
        .library(name: "EditorUI", targets: ["EditorUI"]),
        .executable(name: "archipel-hook", targets: ["archipel-hook"]),
    ],
    dependencies: [
        // highlight.js 11 grammars; EditorUI runs its script directly to get token scopes.
        .package(url: "https://github.com/smittytone/HighlighterSwift.git", exact: "3.1.0"),
    ],
    targets: [
        .target(name: "ArchipelCore"),
        .target(name: "AgentKit", dependencies: ["ArchipelCore"]),
        .target(name: "GitKit"),
        // SwiftUI helpers shared by the inspector and the editor; not a product of its own.
        .target(name: "UISupport"),
        .target(name: "InspectorUI", dependencies: ["GitKit", "UISupport"]),
        .target(
            name: "EditorUI",
            dependencies: ["GitKit", "UISupport", .product(name: "Highlighter", package: "HighlighterSwift")]
        ),
        // Manual verification harness; see Sources/editor-demo/main.swift for usage.
        .executableTarget(name: "editor-demo", dependencies: ["EditorUI"]),
        .executableTarget(name: "archipel-hook"),
        .testTarget(name: "ArchipelCoreTests", dependencies: ["ArchipelCore"]),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit"]),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit"]),
        .testTarget(name: "EditorUITests", dependencies: ["EditorUI"]),
    ],
    swiftLanguageModes: [.v6]
)
