// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentAttention",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentAttentionCore", targets: ["AgentAttentionCore"]),
        .executable(name: "aa-emit", targets: ["AAEmit"]),
        .executable(name: "aa-status", targets: ["AAStatus"]),
        .executable(name: "aa-bridge", targets: ["AABridge"]),
        .executable(name: "aa-session", targets: ["AASession"]),
        .executable(name: "aa-powerd", targets: ["AAPowerd"]),
        .executable(name: "aa-roam", targets: ["AARoam"]),
        .executable(name: "AgentAttention", targets: ["AgentAttentionApp"]),
    ],
    targets: [
        .target(
            name: "AgentAttentionCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AAEmit",
            dependencies: ["AgentAttentionCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AAStatus",
            dependencies: ["AgentAttentionCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AASession",
            dependencies: ["AgentAttentionCore"]
        ),
        .executableTarget(
            name: "AABridge",
            dependencies: ["AgentAttentionCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AAPowerd",
            dependencies: ["AgentAttentionCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AARoam",
            dependencies: ["AgentAttentionCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AgentAttentionApp",
            dependencies: ["AgentAttentionCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AgentAttentionCoreTests",
            dependencies: ["AgentAttentionCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
