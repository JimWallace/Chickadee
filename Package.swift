// swift-tools-version:6.3
import PackageDescription

let strictWarnings: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "Chickadee",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.3"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.12.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/leaf.git", from: "4.5.1"),
        .package(url: "https://github.com/vapor/jwt.git", from: "5.1.2"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.0"),
        .package(url: "https://github.com/vapor-community/CSRF.git", from: "3.1.1"),
        // SwiftLint via SimplyDanny's plugin distribution: ships a pre-built
        // binary so CI / fresh checkouts don't pay a SwiftLint-from-source build.
        // Invoked on demand via `scripts/swiftlint.sh`; no `plugins:` entry on
        // any target, so `swift build` / `swift test` are unaffected.
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.0"),
    ],
    targets: [
        // MARK: - Core library
        .target(
            name: "Core",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/Core",
            exclude: ["README.md"],
            swiftSettings: strictWarnings
        ),

        // MARK: - API Server executable
        .executableTarget(
            name: "chickadee-server",
            dependencies: [
                .target(name: "Core"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "Leaf", package: "leaf"),
                .product(name: "JWT", package: "jwt"),
                .product(name: "CSRF", package: "CSRF"),
            ],
            path: "Sources/APIServer",
            exclude: ["README.md"],
            swiftSettings: strictWarnings
        ),

        // MARK: - Worker executable
        .executableTarget(
            name: "chickadee-runner",
            dependencies: [
                .target(name: "Core"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/Worker",
            exclude: ["README.md"],
            swiftSettings: strictWarnings
        ),

        // MARK: - Tests
        .testTarget(
            name: "CoreTests",
            dependencies: [
                .target(name: "Core")
            ],
            path: "Tests/CoreTests",
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "APITests",
            dependencies: [
                .target(name: "chickadee-server"),
                .product(name: "XCTVapor", package: "vapor"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "CSRF", package: "CSRF"),
                .product(name: "Leaf", package: "leaf"),
            ],
            path: "Tests/APITests",
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "WorkerTests",
            dependencies: [
                .target(name: "chickadee-runner")
            ],
            path: "Tests/WorkerTests",
            swiftSettings: strictWarnings
        ),
    ]
)
