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
        .executable(name: "archipel-hook", targets: ["archipel-hook"]),
    ],
    targets: [
        .target(name: "ArchipelCore"),
        .target(name: "AgentKit", dependencies: ["ArchipelCore"]),
        .target(name: "GitKit"),
        .target(name: "InspectorUI", dependencies: ["GitKit"]),
        .executableTarget(name: "archipel-hook"),
        .testTarget(name: "ArchipelCoreTests", dependencies: ["ArchipelCore"]),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit"]),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit"]),
    ],
    swiftLanguageModes: [.v6]
)
