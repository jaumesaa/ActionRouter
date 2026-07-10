// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ActionRouter",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "ActionRouter", targets: ["ActionRouter"]),
        .library(name: "ActionRouterCoreML", targets: ["ActionRouterCoreML"]),
        .executable(name: "actionrouter", targets: ["ActionRouterCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
    ],
    targets: [
        // Core: no dependencies beyond the OS. Lexical tier + semantic tier
        // driven by any EmbeddingProvider (Apple NLContextualEmbedding ships
        // built in).
        .target(
            name: "ActionRouter"
        ),
        // Optional: Core ML embedding provider for converted sentence
        // embedding models (e.g. multilingual-e5-small; see tools/convert).
        // Separate target so core integrations stay dependency-free.
        .target(
            name: "ActionRouterCoreML",
            dependencies: [
                "ActionRouter",
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        // Live playground: type a query and watch signals, calibrated
        // confidence and the abstention decision update in real time.
        // Run with `swift run RouterPlayground` (macOS only).
        .executableTarget(
            name: "RouterPlayground",
            dependencies: ["ActionRouter", "ActionRouterCoreML"],
            path: "Examples/RouterPlayground"
        ),
        // Demonstration of how AnyAction (a macOS Finder-tools app) would
        // adapt its ToolDefinition catalog to ActionRouter. Demo only; the
        // core library knows nothing about AnyAction.
        .executableTarget(
            name: "AnyActionAdapterDemo",
            dependencies: ["ActionRouter", "ActionRouterCoreML"],
            path: "Examples/AnyActionAdapter"
        ),
        .executableTarget(
            name: "ActionRouterCLI",
            dependencies: [
                "ActionRouter",
                "ActionRouterCoreML",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "ActionRouterTests",
            dependencies: ["ActionRouter"]
        ),
        .testTarget(
            name: "ActionRouterCoreMLTests",
            dependencies: ["ActionRouterCoreML"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
