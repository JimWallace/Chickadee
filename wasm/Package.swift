// swift-tools-version:6.0
import PackageDescription

// Separate package so JavaScriptKit (wasm-only) never enters the main
// Chickadee package's native build graph. Depends on the main package's
// RunnerCore product by path, plus JavaScriptKit. Built for wasm ONLY with the
// Embedded Swift SDK via scripts/build-runner-wasm.sh; the ~130 KB-gzipped
// output is vendored under Public/runner-wasm/.
//
// Embedded specifics:
//   * The bridge uses manual JavaScriptKit interop (JSClosure + dynamic
//     JSObject access) in Sources/RunnerWasm/main.swift. It was written that
//     way because BridgeJS did not build under Embedded Swift at the time. That
//     is no longer true: on JavaScriptKit 0.59 + the Swift 6.4 Embedded SDK a
//     `@JS` export (sync, struct-typed, and async with an async JS callback)
//     compiles, runs in the Node harness, and costs no size once the dynamic
//     bridge it replaces is removed. Moving the bridge across is a deliberate
//     follow-up, because it changes the JS contract (typed `exports.*` instead
//     of `globalThis.runner*` globals). See docs/runner-wasm-swift-6-4-review.md.
//   * swiftLanguageModes [.v5] + the "Extern" experimental feature, matching
//     JavaScriptKit's Embedded example.
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
            linkerSettings: [.unsafeFlags(["-lswiftUnicodeDataTables"])]
        )
    ],
    swiftLanguageModes: [.v5]
)
