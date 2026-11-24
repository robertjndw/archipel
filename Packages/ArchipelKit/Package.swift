// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ArchipelKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "ArchipelCore", targets: ["ArchipelCore"]),
        .library(name: "AgentKit", targets: ["AgentKit"]),
        .library(name: "GitKit", targets: ["GitKit"]),
        .library(name: "ACPKit", targets: ["ACPKit"]),
        .library(name: "InspectorUI", targets: ["InspectorUI"]),
        .library(name: "EditorUI", targets: ["EditorUI"]),
        .library(name: "ChatUI", targets: ["ChatUI"]),
        .executable(name: "archipel-hook", targets: ["archipel-hook"]),
    ],
    dependencies: [
        // highlight.js 11 grammars; EditorUI runs its script directly to get token scopes.
        .package(url: "https://github.com/smittytone/HighlighterSwift.git", exact: "3.1.0"),
        // CommonMark plus GitHub's extensions (tables, task lists, strikethrough) for the Markdown preview.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
    ],
    targets: [
        .target(name: "ArchipelCore"),
        .target(name: "AgentKit", dependencies: ["ArchipelCore"]),
        .target(name: "GitKit"),
        // The Agent Client Protocol client: wire types, the connection to an agent process, and
        // the registry its adapter programs are installed from. No UI and no other target.
        .target(name: "ACPKit"),
        // SwiftUI helpers shared by the inspector and the editor; not a product of its own.
        .target(name: "UISupport"),
        .target(name: "InspectorUI", dependencies: ["GitKit", "UISupport"]),
        .target(
            name: "EditorUI",
            dependencies: [
                "GitKit",
                "UISupport",
                .product(name: "Highlighter", package: "HighlighterSwift"),
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        // The native chat: one conversation with an agent over ACP, and how its process is launched.
        .target(name: "ChatUI", dependencies: ["ACPKit", "AgentKit", "ArchipelCore", "EditorUI", "UISupport"]),
        // Manual verification harness; see Sources/editor-demo/main.swift for usage.
        .executableTarget(name: "editor-demo", dependencies: ["EditorUI"]),
        .executableTarget(name: "archipel-hook"),
        .testTarget(name: "ArchipelCoreTests", dependencies: ["ArchipelCore"]),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit"]),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit"]),
        .testTarget(name: "ACPKitTests", dependencies: ["ACPKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "EditorUITests", dependencies: ["EditorUI"]),
        .testTarget(name: "InspectorUITests", dependencies: ["InspectorUI"]),
        .testTarget(name: "ChatUITests", dependencies: ["ChatUI"]),
    ],
    swiftLanguageModes: [.v6]
)
