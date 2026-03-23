// Tests/WorkerTests/ScriptInvocationTests.swift
//
// Unit tests for scriptInvocation(for:) — verifies that the correct
// interpreter is selected for each file extension, shebang line, and
// Python-heuristic fallback.

import XCTest
@testable import chickadee_runner
import Foundation

final class ScriptInvocationTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-inv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Helpers

    private func makeScript(name: String, content: String = "echo hi") -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Extension-based dispatch

    func testShExtension_usesSh() {
        let script = makeScript(name: "test.sh")
        let inv = scriptInvocation(for: script)
        XCTAssertEqual(inv.executableURL.path, "/bin/sh")
        XCTAssertEqual(inv.arguments, [script.path])
    }

    func testBashExtension_usesBash() {
        let script = makeScript(name: "test.bash")
        let inv = scriptInvocation(for: script)
        XCTAssertTrue(inv.executableURL.path.hasSuffix("env"),
                      "Expected env wrapper, got \(inv.executableURL.path)")
        XCTAssertEqual(inv.arguments.first, "bash")
    }

    func testZshExtension_usesZsh() {
        let script = makeScript(name: "test.zsh")
        let inv = scriptInvocation(for: script)
        XCTAssertTrue(inv.executableURL.path.hasSuffix("env"))
        XCTAssertEqual(inv.arguments.first, "zsh")
    }

    func testPyExtension_usesPython3() {
        let script = makeScript(name: "test.py")
        let inv = scriptInvocation(for: script)
        XCTAssertTrue(inv.executableURL.path.hasSuffix("env"))
        XCTAssertEqual(inv.arguments.first, "python3")
        // Python invocation uses -c <bootstrap> <script>
        XCTAssertTrue(inv.arguments.contains("-c"),
                      "Python invocation should pass bootstrap via -c")
        XCTAssertTrue(inv.arguments.last == script.path,
                      "Script path should be last argument")
    }

    func testRbExtension_usesRuby() {
        let script = makeScript(name: "test.rb")
        let inv = scriptInvocation(for: script)
        XCTAssertTrue(inv.executableURL.path.hasSuffix("env"))
        XCTAssertEqual(inv.arguments.first, "ruby")
    }

    func testPlExtension_usesPe() {
        let script = makeScript(name: "test.pl")
        let inv = scriptInvocation(for: script)
        XCTAssertTrue(inv.executableURL.path.hasSuffix("env"))
        XCTAssertEqual(inv.arguments.first, "perl")
    }

    func testJsExtension_usesNode() {
        let script = makeScript(name: "test.js")
        let inv = scriptInvocation(for: script)
        XCTAssertTrue(inv.executableURL.path.hasSuffix("env"))
        XCTAssertEqual(inv.arguments.first, "node")
    }

    // MARK: - Shebang dispatch (extensionless files)

    func testShebangPython_usesPython3() {
        let script = makeScript(name: "test_nopy", content: "#!/usr/bin/env python3\nprint('hi')")
        let inv = scriptInvocation(for: script)
        XCTAssertEqual(inv.arguments.first, "python3")
        XCTAssertTrue(inv.arguments.contains("-c"))
    }

    func testShebangBash_usesBash() {
        let script = makeScript(name: "test_nobash", content: "#!/bin/bash\necho hi")
        let inv = scriptInvocation(for: script)
        XCTAssertEqual(inv.arguments.first, "bash")
    }

    func testShebangSh_usesSh() {
        let script = makeScript(name: "test_nosh", content: "#!/bin/sh\necho hi")
        let inv = scriptInvocation(for: script)
        XCTAssertEqual(inv.executableURL.path, "/bin/sh")
    }

    func testShebangNode_usesNode() {
        let script = makeScript(name: "test_nojs", content: "#!/usr/bin/env node\nconsole.log('hi')")
        let inv = scriptInvocation(for: script)
        XCTAssertEqual(inv.arguments.first, "node")
    }

    func testShebangRuby_usesRuby() {
        let script = makeScript(name: "test_norb", content: "#!/usr/bin/env ruby\nputs 'hi'")
        let inv = scriptInvocation(for: script)
        XCTAssertEqual(inv.arguments.first, "ruby")
    }

    // MARK: - Python heuristic (no extension, no shebang)

    func testPythonImport_heuristicDetectsPython() {
        let script = makeScript(name: "test_heuristic", content: "import os\nprint(os.getcwd())")
        let inv = scriptInvocation(for: script)
        XCTAssertEqual(inv.arguments.first, "python3",
                       "Script starting with 'import' should be detected as Python")
    }

    func testPythonDef_heuristicDetectsPython() {
        let script = makeScript(name: "test_heuristic2", content: "def foo():\n    pass\n\nfoo()")
        let inv = scriptInvocation(for: script)
        XCTAssertEqual(inv.arguments.first, "python3")
    }

    // MARK: - Fallback

    func testUnknownExtension_fallsBackToSh() {
        let script = makeScript(name: "test.unknown", content: "echo hi")
        let inv = scriptInvocation(for: script)
        // Non-executable file with unknown extension should fall back to /bin/sh
        XCTAssertEqual(inv.executableURL.path, "/bin/sh")
    }
}
