// Tests/WorkerTests/ScriptInvocationTests.swift
//
// Unit tests for scriptInvocation(for:) — verifies that the correct
// interpreter is selected for each file extension, shebang line, and
// Python-heuristic fallback.

import Testing
@testable import chickadee_runner
import Foundation

// final class so deinit can remove the per-test temp directory.
final class ScriptInvocationTests {

    private let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-inv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Helpers

    private func makeScript(name: String, content: String = "echo hi") -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Extension-based dispatch: env-wrapper interpreters

    @Test(arguments: zip(
        ["test.bash", "test.zsh", "test.rb", "test.pl", "test.js"],
        ["bash",      "zsh",      "ruby",    "perl",    "node"]
    ))
    func extensionUsesEnvWrapper(filename: String, interpreter: String) {
        let inv = scriptInvocation(for: makeScript(name: filename))
        #expect(inv.executableURL.path.hasSuffix("env"))
        #expect(inv.arguments.first == interpreter)
    }

    // .sh is a direct /bin/sh invocation, not an env wrapper.
    @Test func shExtensionUsesSh() {
        let script = makeScript(name: "test.sh")
        let inv = scriptInvocation(for: script)
        #expect(inv.executableURL.path == "/bin/sh")
        #expect(inv.arguments == [script.path])
    }

    // .py passes a bootstrap via -c and appends the script path last.
    @Test func pyExtensionUsesPython3() {
        let script = makeScript(name: "test.py")
        let inv = scriptInvocation(for: script)
        #expect(inv.executableURL.path.hasSuffix("env"))
        #expect(inv.arguments.first == "python3")
        #expect(inv.arguments.contains("-c"), "Python invocation should pass bootstrap via -c")
        #expect(inv.arguments.last == script.path, "Script path should be last argument")
    }

    // MARK: - Shebang dispatch (extensionless files)

    @Test(arguments: zip(
        ["#!/bin/bash\necho hi",               "#!/usr/bin/env node\nconsole.log('hi')", "#!/usr/bin/env ruby\nputs 'hi'"],
        ["bash",                               "node",                                    "ruby"]
    ))
    func shebangUsesEnvWrapper(content: String, interpreter: String) {
        let inv = scriptInvocation(for: makeScript(name: "test_script", content: content))
        #expect(inv.arguments.first == interpreter)
    }

    @Test func shebangPythonUsesPython3() {
        let script = makeScript(name: "test_nopy", content: "#!/usr/bin/env python3\nprint('hi')")
        let inv = scriptInvocation(for: script)
        #expect(inv.arguments.first == "python3")
        #expect(inv.arguments.contains("-c"))
    }

    @Test func extensionlessDisplayNameWithPythonShebangUsesPython3() {
        let script = makeScript(name: "BMI Boundary Cases", content: "#!/usr/bin/env python3\nprint('hi')")
        let inv = scriptInvocation(for: script)
        #expect(inv.arguments.first == "python3")
        #expect(inv.arguments.last == script.path)
    }

    @Test func leadingBlankBeforePythonShebangUsesPython3() {
        let script = makeScript(name: "BMI Boundary Cases", content: "\n#!/usr/bin/env python3\nprint('hi')")
        let inv = scriptInvocation(for: script)
        #expect(inv.arguments.first == "python3")
    }

    @Test func shebangShUsesSh() {
        let script = makeScript(name: "test_nosh", content: "#!/bin/sh\necho hi")
        let inv = scriptInvocation(for: script)
        #expect(inv.executableURL.path == "/bin/sh")
    }

    // MARK: - Python heuristic (no extension, no shebang)

    @Test(arguments: [
        "import os\nprint(os.getcwd())",
        "def foo():\n    pass\n\nfoo()"
    ])
    func pythonHeuristic(content: String) {
        let inv = scriptInvocation(for: makeScript(name: "test_heuristic", content: content))
        #expect(inv.arguments.first == "python3", "Script starting with 'import' or 'def' should be detected as Python")
    }

    // MARK: - Fallback

    @Test func unknownExtensionFallsBackToSh() {
        let script = makeScript(name: "test.unknown", content: "echo hi")
        let inv = scriptInvocation(for: script)
        #expect(inv.executableURL.path == "/bin/sh")
    }
}
