// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "llmdb",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/alexmx/swift-cli-mcp.git", from: "1.1.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", branch: "main"),
        .package(url: "https://github.com/toon-format/toon-swift.git", from: "0.3.0")
    ],
    targets: [
        .executableTarget(
            name: "llmdb",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftMCP", package: "swift-cli-mcp"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "ToonFormat", package: "toon-swift")
            ]
        ),
        .executableTarget(
            name: "llmdb-fixture",
            dependencies: [],
            path: "Sources/Fixture"
        ),
        .testTarget(
            name: "llmdbTests",
            dependencies: ["llmdb"]
        )
    ]
)
