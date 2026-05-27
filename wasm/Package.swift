// swift-tools-version:6.0
import PackageDescription

// Separate package so JavaScriptKit (wasm-only) never enters the main
// Chickadee package's native build graph. Depends on the main package's
// RunnerCore product by path, plus JavaScriptKit. Built for wasm only, via
// scripts/build-runner-wasm.sh; the output is vendored under Public/runner-wasm/.
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
            ],
            swiftSettings: [.enableExperimentalFeature("Extern")],
            plugins: [.plugin(name: "BridgeJS", package: "JavaScriptKit")]
        )
    ]
)
