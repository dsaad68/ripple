// swift-tools-version: 6.1
import PackageDescription

// Ripple -- a headless CLI built on DeepAgents.swift: an interactive REPL/TUI (`ripple chat`)
// and a TOML-driven scenario harness (`ripple run`). It owns its own agent presets (a fork of
// the Mispher assembly) and depends on the DeepAgents package (framework + MLX + macOS tools)
// via a local path.
let package = Package(
    name: "Ripple",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "ripple", targets: ["ripple"])
    ],
    dependencies: [
        .package(url: "https://github.com/dsaad68/deepagents-swift.git", from: "0.2.3"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "ripple",
            dependencies: [
                .product(name: "DeepAgents", package: "deepagents-swift"),
                .product(name: "DeepAgentsMLX", package: "deepagents-swift"),
                .product(name: "DeepAgentsOpenAI", package: "deepagents-swift"),
                .product(name: "DeepAgentsAnthropic", package: "deepagents-swift"),
                .product(name: "DeepAgentsMacTools", package: "deepagents-swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "RippleTests",
            dependencies: [
                "ripple",
                .product(name: "DeepAgents", package: "deepagents-swift"),
                .product(name: "DeepAgentsMLX", package: "deepagents-swift"),
                .product(name: "DeepAgentsOpenAI", package: "deepagents-swift"),
                .product(name: "DeepAgentsAnthropic", package: "deepagents-swift"),
                .product(name: "DeepAgentsMacTools", package: "deepagents-swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "RippleIntegrationTests",
            dependencies: [
                "ripple",
                .product(name: "DeepAgents", package: "deepagents-swift"),
                .product(name: "DeepAgentsMLX", package: "deepagents-swift"),
                .product(name: "DeepAgentsOpenAI", package: "deepagents-swift"),
                .product(name: "DeepAgentsAnthropic", package: "deepagents-swift"),
                .product(name: "DeepAgentsMacTools", package: "deepagents-swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            swiftSettings: swiftSettings
        )
    ]
)

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .swiftLanguageMode(.v6)
]
