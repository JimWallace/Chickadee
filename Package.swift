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
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.4"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.12.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/leaf.git", from: "4.5.1"),
        .package(url: "https://github.com/vapor/jwt.git", from: "5.1.2"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.0"),
        .package(url: "https://github.com/vapor-community/CSRF.git", from: "3.1.1"),
        // Already in the resolved graph transitively via Vapor; declared
        // explicitly so the MCP support-file fetcher can build a dedicated,
        // no-redirect HTTPClient (the shared Vapor client follows redirects).
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.34.0"),
        // SwiftLint via SimplyDanny's plugin distribution: ships a pre-built
        // binary so CI / fresh checkouts don't pay a SwiftLint-from-source build.
        // Invoked on demand via `scripts/swiftlint.sh`; no `plugins:` entry on
        // any target, so `swift build` / `swift test` are unaffected.
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.64.0"),
        // The worker's one subprocess-launch primitive. Replaces a hand-rolled
        // fork()/execve()/waitpid() path that existed because Foundation's
        // Process deadlocked forking from the multithreaded daemon (issue
        // #1139); Subprocess spawns without that hazard and is CI-tested on the
        // distributions the runner ships on.
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.0"),
        // Subprocess speaks `FilePath` at its API boundary. Already in the
        // resolved graph as its dependency; declared explicitly because a
        // target may only import what it declares.
        .package(url: "https://github.com/apple/swift-system.git", from: "1.5.0"),
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
                .target(name: "RunnerCore"),
                .product(name: "Crypto", package: "swift-crypto"),
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
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
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
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            path: "Sources/Worker",
            exclude: ["README.md"],
            swiftSettings: strictWarnings,
            // Compiles Tools/runner-support/* into the binary. Replaces 2,223
            // lines of hand-typed string literals that mirrored those files;
            // see the plugin for why this is codegen and not `resources:`.
            plugins: [.plugin(name: "EmbedRunnerSupport")]
        ),

        // MARK: - Build-tool plugins
        .plugin(
            name: "EmbedRunnerSupport",
            capability: .buildTool(),
            path: "Plugins/EmbedRunnerSupport"
        ),

        // MARK: - Shared test support
        //
        // Test-only infrastructure that more than one test target needs. It is
        // a plain `.target` rather than a `.testTarget` because SwiftPM test
        // targets cannot depend on one another, and it lives under `Tests/`
        // rather than `Sources/` because nothing here ships: `WedgeWatchdog`
        // aborts the process on a stall, which is diagnosis for CI and would
        // be a liability in the server or the runner.
        //
        // The alternative shapes were both worse. Copying the file into each
        // test target is the drift class this repo keeps paying for. Sharing
        // via `path:`/`sources:` cannot work: SwiftPM assigns each source file
        // to exactly one target, so the shared directory can appear in only
        // one `sources:` list — the only way to fake it is a symlink, which
        // compiles two independent copies of the type while reading in review
        // as one file.
        .target(
            name: "ChickadeeTestSupport",
            path: "Tests/TestSupport",
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
                .target(name: "ChickadeeTestSupport"),
                .product(name: "VaporTesting", package: "vapor"),
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
                .target(name: "ChickadeeTestSupport"),
            ],
            path: "Tests/WorkerTests",
            swiftSettings: strictWarnings
        ),
    ]
)
