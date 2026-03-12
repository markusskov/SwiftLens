// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SwiftLens",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "swift-lens", targets: ["SwiftLens"]),
        .library(name: "SwiftLensCore", targets: ["SwiftLensCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.4.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/swiftlang/indexstore-db.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "SwiftLensCore",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "IndexStore", package: "indexstore-db"),
            ]
        ),
        .executableTarget(
            name: "SwiftLens",
            dependencies: [
                "SwiftLensCore",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "SwiftLensCoreTests",
            dependencies: ["SwiftLensCore"]
        ),
    ]
)
