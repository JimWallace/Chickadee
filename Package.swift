// swift-tools-version:6.3
import PackageDescription

let strictWarnings: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "Chickadee",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        // Exposed so the wasm bridge sub-package (wasm/) can depend on the pure
        // extraction logic without pulling in the rest of Chickadee.
        .library(name: "RunnerCore", targets: ["RunnerCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.3"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.12.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/leaf.git", from: "4.5.1"),
        .package(url: "https://github.com/vapor/jwt.git", from: "5.1.2"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.15.1"),
        .package(url: "https://github.com/vapor-community/CSRF.git", from: "3.1.1"),
        // SwiftLint via SimplyDanny's plugin distribution: ships a pre-built
        // binary so CI / fresh checkouts don't pay a SwiftLint-from-source build.
        // Invoked on demand via `scripts/swiftlint.sh`; no `plugins:` entry on
        // any target, so `swift build` / `swift test` are unaffected.
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.0"),
    ],
    targets: [
        // MARK: - Runner core
        //
        // Dependency-free (Swift stdlib only) so it can compile to wasm32 and be
        // shared by the native worker AND the browser runner via a JS bridge.
        // The substrate-free home for grading logic shared across runners —
        // currently notebook → Python extraction; in time, script dispatch,
        // output interpretation, and the shared suite-execution orchestration.
        .target(
            name: "RunnerCore",
            path: "Sources/RunnerCore",
            swiftSettings: strictWarnings
        ),

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

        // MARK: - API Server library
        //
        // The bulk of the server lives in this library so tests (and any
        // future consumers) don't need to depend on an executable target.
        // Executable-target deps force every `swift test` to relink the
        // binary; routing the test target through this library removes
        // that cost.
        .target(
            name: "APIServer",
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

        // MARK: - API Server executable (thin wrapper)
        //
        // Just calls `runAPIServer()` from the APIServer library.  The
        // executable name is preserved (`chickadee-server`) so deploy
        // scripts and Dockerfiles continue to find the binary at
        // `.build/release/chickadee-server`.
        .executableTarget(
            name: "chickadee-server",
            dependencies: [
                .target(name: "APIServer")
            ],
            path: "Sources/chickadee-server",
            swiftSettings: strictWarnings
        ),

        // MARK: - Worker executable
        .executableTarget(
            name: "chickadee-runner",
            dependencies: [
                .target(name: "Core"),
                .target(name: "RunnerCore"),
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
                .target(name: "APIServer"),
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
                .target(name: "chickadee-runner"),
                .target(name: "RunnerCore"),
            ],
            path: "Tests/WorkerTests",
            swiftSettings: strictWarnings
        ),
    ]
)
