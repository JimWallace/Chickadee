// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Chickadee",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.6.0"),
        .package(url: "https://github.com/vapor/leaf.git", from: "4.3.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        // MARK: - Core library
        .target(
            name: "Core",
            dependencies: [],
            path: "Sources/Core"
        ),

        // MARK: - API Server executable
        .executableTarget(
            name: "chickadee-server",
            dependencies: [
                .target(name: "Core"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "Leaf", package: "leaf"),
            ],
            path: "Sources/APIServer"
        ),

        // MARK: - Worker executable
        .executableTarget(
            name: "chickadee-runner",
            dependencies: [
                .target(name: "Core"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/Worker"
        ),

        // MARK: - Tests
        .testTarget(
            name: "CoreTests",
            dependencies: [
                .target(name: "Core"),
            ],
            path: "Tests/CoreTests"
        ),
        .testTarget(
            name: "APITests",
            dependencies: [
                .target(name: "chickadee-server"),
                .product(name: "XCTVapor", package: "vapor"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
            ],
            path: "Tests/APITests"
        ),
        .testTarget(
            name: "WorkerTests",
            dependencies: [
                .target(name: "chickadee-runner"),
            ],
            path: "Tests/WorkerTests"
        ),
    ]
)
