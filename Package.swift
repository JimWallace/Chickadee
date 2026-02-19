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
            name: "APIServer",
            dependencies: [
                .target(name: "Core"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
            ],
            path: "Sources/APIServer"
        ),

        // MARK: - Worker executable
        .executableTarget(
            name: "Worker",
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
                .target(name: "APIServer"),
                .product(name: "XCTVapor", package: "vapor"),
            ],
            path: "Tests/APITests"
        ),
        .testTarget(
            name: "WorkerTests",
            dependencies: [
                .target(name: "Worker"),
            ],
            path: "Tests/WorkerTests"
        ),
    ]
)
