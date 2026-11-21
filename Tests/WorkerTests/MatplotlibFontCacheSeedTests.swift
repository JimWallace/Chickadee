// Tests/WorkerTests/MatplotlibFontCacheSeedTests.swift
//
// The sandbox gives every test script an empty HOME, so matplotlib rebuilt its
// font cache in every Python test that imported pyplot. The Python bootstrap
// now copies the image's prebuilt `fontlist-*.json` into the fresh HOME. These
// tests run the real bootstrap with `python3` and check where the copy lands,
// that it never overwrites, and that a host without the prebuilt cache is
// unchanged. They do not need matplotlib: the copy is plain file work.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(1))) final class MatplotlibFontCacheSeedTests {

    private let root: URL
    private let source: URL
    private let home: URL
    private let workspace: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-mplseed-\(UUID().uuidString)")
        source = root.appendingPathComponent("prebuilt")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let harness = NativeGradingHarness(
            language: .python, solutionFilename: "solution.py", timeLimitSeconds: 30)
        workspace = try harness.makeWorkspace(
            submission: "value = 1\n",
            scripts: ["publictest_seed.py": "if student_module.value == 1:\n    passed()\nfailed('value')\n"])
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: workspace)
    }

    /// Where matplotlib reads its cache when MPLCONFIGDIR is unset.
    private var defaultCacheDirectory: URL {
        #if os(Linux)
        return home.appendingPathComponent(".cache/matplotlib")
        #else
        return home.appendingPathComponent(".matplotlib")
        #endif
    }

    /// Runs the bootstrap on the workspace's test with HOME set to `home`.
    /// The invocation is `/usr/bin/env python3 -c <bootstrap> <script>`, and
    /// `runTool` runs `/usr/bin/env <argv>`, so the arguments pass through.
    private func runBootstrap(
        fontCacheSource: String, extraEnvironment: [String: String] = [:]
    ) async throws -> Int32 {
        let invocation = pythonInvocation(
            for: workspace.appendingPathComponent("publictest_seed.py"), fontCacheSource: fontCacheSource)
        var environment = ["HOME": home.path]
        environment.merge(extraEnvironment) { _, new in new }
        let run = try await runTool(
            invocation.arguments,
            workingDirectory: workspace,
            extraEnvironment: environment,
            removingEnvironment: ["MPLCONFIGDIR", "XDG_CACHE_HOME"].filter { extraEnvironment[$0] == nil })
        return run.exitCode
    }

    @Test func thePrebuiltCacheIsCopiedIntoTheFreshHome() async throws {
        try "{\"_version\": 1}".write(
            to: source.appendingPathComponent("fontlist-v390.json"), atomically: true, encoding: .utf8)
        try "ignored".write(to: source.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)

        #expect(try await runBootstrap(fontCacheSource: source.path) == 0)

        let copied = defaultCacheDirectory.appendingPathComponent("fontlist-v390.json")
        #expect(try String(contentsOf: copied, encoding: .utf8) == "{\"_version\": 1}")
        #expect(!FileManager.default.fileExists(atPath: defaultCacheDirectory.appendingPathComponent("other.txt").path))
    }

    @Test func anMPLCONFIGDIRIsHonoured() async throws {
        try "{}".write(
            to: source.appendingPathComponent("fontlist-v390.json"), atomically: true, encoding: .utf8)
        let config = root.appendingPathComponent("mplconfig")

        let status = try await runBootstrap(
            fontCacheSource: source.path, extraEnvironment: ["MPLCONFIGDIR": config.path])
        #expect(status == 0)

        #expect(FileManager.default.fileExists(atPath: config.appendingPathComponent("fontlist-v390.json").path))
        #expect(!FileManager.default.fileExists(atPath: defaultCacheDirectory.path))
    }

    @Test func anExistingCacheIsNotOverwritten() async throws {
        try "prebuilt".write(
            to: source.appendingPathComponent("fontlist-v390.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: defaultCacheDirectory, withIntermediateDirectories: true)
        let existing = defaultCacheDirectory.appendingPathComponent("fontlist-v390.json")
        try "already here".write(to: existing, atomically: true, encoding: .utf8)

        #expect(try await runBootstrap(fontCacheSource: source.path) == 0)

        #expect(try String(contentsOf: existing, encoding: .utf8) == "already here")
    }

    @Test func aHostWithoutThePrebuiltCacheIsUnchanged() async throws {
        let missing = root.appendingPathComponent("does-not-exist").path

        #expect(try await runBootstrap(fontCacheSource: missing) == 0)

        #expect(!FileManager.default.fileExists(atPath: defaultCacheDirectory.path))
    }

    @Test func theDefaultBootstrapNamesTheImagePath() {
        let invocation = pythonInvocation(for: workspace.appendingPathComponent("publictest_seed.py"))
        let bootstrap = invocation.arguments[2]
        #expect(bootstrap.contains("_ck_seed_matplotlib_font_cache(\"\(matplotlibFontCacheSource)\")"))
        #expect(bootstrap.contains("import test_runtime as _tr"))
    }
}
