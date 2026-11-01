// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "llmdb",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/alexmx/swift-cli-mcp.git", from: "1.1.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "llmdb",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftMCP", package: "swift-cli-mcp"),
                .product(name: "Subprocess", package: "swift-subprocess")
            ]
        ),
        .executableTarget(
            name: "llmdb-fixture",
            dependencies: [],
            path: "Sources/Fixture"
        ),
        .executableTarget(
            name: "llmdb-throw-fixture",
            dependencies: [],
            path: "Sources/ThrowFixture"
        ),
        .testTarget(
            name: "llmdbTests",
            dependencies: ["llmdb"]
        )
    ]
)
