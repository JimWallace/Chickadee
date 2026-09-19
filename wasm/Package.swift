// swift-tools-version:6.0
import PackageDescription

// Separate package so JavaScriptKit (wasm-only) never enters the main
// Chickadee package's native build graph. Depends on the main package's
// RunnerCore product by path, plus JavaScriptKit. Built for wasm ONLY with the
// Embedded Swift SDK via scripts/build-runner-wasm.sh; the ~130 KB-gzipped
// output is vendored under Public/runner-wasm/.
//
// Embedded specifics:
//   * The bridge is BridgeJS: `@JS` structs and functions in
//     Sources/RunnerWasm/Bridge.swift, with the plugin generating the JS glue
//     and a `.d.ts` that IS the contract. It was hand-marshalled `JSClosure`s
//     over dynamic `JSObject` access until Swift 6.4, because BridgeJS did not
//     build under Embedded Swift before then. The legacy `globalThis.runner*`
//     entry points are a JS adapter over the typed exports
//     (wasm/loader/runner-core-entry.js). See docs/runner-wasm-swift-6-4-review.md.
//   * Swift 6 language mode, like the main package. The bridge carried
//     `swiftLanguageModes: [.v5]` from JavaScriptKit's Embedded example, and
//     while it was hand-marshalled it needed to: `BrowserScriptExecutor` held
//     `JSObject`s, which are not `Sendable`, behind an `async` protocol. With
//     BridgeJS the executor holds the typed closures the plugin lifts, the
//     package builds clean under strict concurrency (measured: zero
//     diagnostics on the 6.4 Embedded SDK), and the language mode is one
//     less thing that differs from the rest of the repository. The "Extern"
//     experimental feature stays: BridgeJS's generated code uses
//     `@_extern(wasm)`.
//   * -Osize: the bridge is not hot (one call per submission), so the size
//     optimizer's ~10 KB raw / ~3 KB gzip saving is free. Measured on the 6.4
//     Embedded SDK with the Node output-contract harness green.
//   * Links libswiftUnicodeDataTables, which the embedded SDK ships but does
//     not auto-link (JavaScriptKit's string handling needs the Unicode tables).
let package = Package(
    name: "RunnerWasm",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "Chickadee", path: ".."),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", from: "0.56.1"),
    ],
    targets: [
        .executableTarget(
            name: "RunnerWasm",
            dependencies: [
                .product(name: "RunnerCore", package: "Chickadee"),
                "JavaScriptKit",
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
            ],
            swiftSettings: [.enableExperimentalFeature("Extern"), .unsafeFlags(["-Osize"])],
            linkerSettings: [.unsafeFlags(["-lswiftUnicodeDataTables"])],
            plugins: [.plugin(name: "BridgeJS", package: "JavaScriptKit")]
        )
    ],
    swiftLanguageModes: [.v6]
)
