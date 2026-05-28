// swift-tools-version:6.0
import PackageDescription

// Separate package so JavaScriptKit (wasm-only) never enters the main
// Chickadee package's native build graph. Depends on the main package's
// RunnerCore product by path, plus JavaScriptKit. Built for wasm ONLY with the
// Embedded Swift SDK via scripts/build-runner-wasm.sh; the ~350 KB-gzipped
// output is vendored under Public/runner-wasm/.
//
// Embedded specifics:
//   * No BridgeJS plugin (it's incompatible with Embedded Swift) — the bridge
//     uses manual JavaScriptKit interop in Sources/RunnerWasm/main.swift.
//   * swiftLanguageModes [.v5] + the "Extern" experimental feature, matching
//     JavaScriptKit's Embedded example.
//   * Links libswiftUnicodeDataTables, which the embedded SDK ships but does
//     not auto-link (JavaScriptKit's string handling needs the Unicode tables).
let package = Package(
    name: "RunnerWasm",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "Chickadee", path: ".."),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", from: "0.53.0"),
    ],
    targets: [
        .executableTarget(
            name: "RunnerWasm",
            dependencies: [
                .product(name: "RunnerCore", package: "Chickadee"),
                "JavaScriptKit",
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
            ],
            swiftSettings: [.enableExperimentalFeature("Extern")],
            linkerSettings: [.unsafeFlags(["-lswiftUnicodeDataTables"])]
        )
    ],
    swiftLanguageModes: [.v5]
)
