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
        .executable(name: "actionrouter", targets: ["ActionRouterCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "ActionRouter"
        ),
        .executableTarget(
            name: "ActionRouterCLI",
            dependencies: [
                "ActionRouter",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "ActionRouterTests",
            dependencies: ["ActionRouter"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
