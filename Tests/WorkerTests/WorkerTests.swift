import XCTest
@testable import chickadee_runner
import Foundation

final class WorkerTests: XCTestCase {

    // MARK: - Setup

    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-worker-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeScript(_ body: String, name: String = "test.sh") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: url.path
        )
        return url
    }

    private func writeSecretFile(_ value: String, name: String = ".worker-secret") throws -> String {
        let url = tmpDir.appendingPathComponent(name)
        try value.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func requireStableLinuxSandboxRunner() throws {
#if os(Linux)
        if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" {
            throw XCTSkip("Sandboxed runner tests are unstable on GitHub's containerized Linux runners.")
        }
#endif
    }

    // MARK: - UnsandboxedScriptRunner: exit code mapping

    func testScriptExitZeroReportsExitCodeZero() async throws {
        let script = try writeScript("#!/bin/sh\nexit 0")
        let runner = UnsandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 5)
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertFalse(output.timedOut)
    }

    func testScriptExitOneReportsExitCodeOne() async throws {
        let script = try writeScript("#!/bin/sh\nexit 1")
        let runner = UnsandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 5)
        XCTAssertEqual(output.exitCode, 1)
        XCTAssertFalse(output.timedOut)
    }

    func testScriptExitTwoReportsExitCodeTwo() async throws {
        let script = try writeScript("#!/bin/sh\nexit 2")
        let runner = UnsandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 5)
        XCTAssertEqual(output.exitCode, 2)
        XCTAssertFalse(output.timedOut)
    }

    // MARK: - UnsandboxedScriptRunner: output capture

    func testStdoutIsCaptured() async throws {
        let script = try writeScript("#!/bin/sh\necho 'hello world'\nexit 0")
        let runner = UnsandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 5)
        XCTAssertTrue(output.stdout.contains("hello world"))
    }

    func testStderrIsCaptured() async throws {
        let script = try writeScript("#!/bin/sh\necho 'oops' >&2\nexit 0")
        let runner = UnsandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 5)
        XCTAssertTrue(output.stderr.contains("oops"))
    }

    func testStdoutAndStderrAreSeparate() async throws {
        let script = try writeScript("#!/bin/sh\necho 'out'\necho 'err' >&2\nexit 0")
        let runner = UnsandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 5)
        XCTAssertTrue(output.stdout.contains("out"))
        XCTAssertFalse(output.stdout.contains("err"))
        XCTAssertTrue(output.stderr.contains("err"))
        XCTAssertFalse(output.stderr.contains("out"))
    }

    // MARK: - UnsandboxedScriptRunner: env passthrough (Phase 1, issue #461)

    func testScriptReceivesEnvVarFromRunner() async throws {
        let script = try writeScript("""
        #!/bin/sh
        echo "seed=$CHICKADEE_ASSIGNMENT_SEED" >&2
        exit 0
        """)
        let runner = UnsandboxedScriptRunner()
        let output = await runner.run(
            script: script,
            workDir: tmpDir,
            timeLimitSeconds: 5,
            env: ["CHICKADEE_ASSIGNMENT_SEED": "deadbeef" + String(repeating: "c0ffee", count: 9) + "ba"]
        )
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertTrue(
            output.stderr.contains("seed=deadbeef"),
            "Expected env var to reach subprocess stderr; got: \(output.stderr)"
        )
    }

    func testScriptEnvVarUnsetWhenNoOverride() async throws {
        // Sanity check: empty env override = no var set. The script prints the
        // raw env-var expansion; an unset var expands to an empty string.
        let script = try writeScript("""
        #!/bin/sh
        echo "seed=[$CHICKADEE_ASSIGNMENT_SEED]" >&2
        exit 0
        """)
        let runner = UnsandboxedScriptRunner()
        // Ensure parent doesn't have the var set in this test's environment.
        unsetenv("CHICKADEE_ASSIGNMENT_SEED")
        let output = await runner.run(
            script: script,
            workDir: tmpDir,
            timeLimitSeconds: 5,
            env: [:]
        )
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertTrue(
            output.stderr.contains("seed=[]"),
            "Expected unset env var when overrides is empty and parent didn't set it; got: \(output.stderr)"
        )
    }

    // MARK: - UnsandboxedScriptRunner: timeout

    func testScriptTimesOut() async throws {
        let script = try writeScript("#!/bin/sh\nsleep 60\nexit 0")
        let runner = UnsandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 1)
        XCTAssertTrue(output.timedOut, "Script sleeping 60s should time out with a 1s limit")
        XCTAssertEqual(output.exitCode, -1)
        XCTAssertLessThan(output.executionTimeMs, 10_000, "Timed-out script should be reaped promptly")
    }

#if os(Linux)
    func testScriptTimeoutReapsBackgroundChildProcess() async throws {
        let script = try writeScript("""
        #!/bin/sh
        sleep 60 &
        wait
        """)
        let runner = UnsandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 1)
        XCTAssertTrue(output.timedOut, "Timed-out script with a background child should still time out")
        XCTAssertEqual(output.exitCode, -1)
        XCTAssertLessThan(
            output.executionTimeMs,
            10_000,
            "Timed-out script should reap inherited stdout/stderr handles from background children"
        )
    }
#endif

    // MARK: - UnsandboxedScriptRunner: working directory

    func testWorkDirIsSetCorrectly() async throws {
        let script = try writeScript("#!/bin/sh\ntouch marker.txt\nexit 0")
        let runner = UnsandboxedScriptRunner()
        _ = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 5)
        let markerPath = tmpDir.appendingPathComponent("marker.txt").path
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: markerPath),
            "Script should create marker.txt in the supplied working directory"
        )
    }

    // MARK: - SandboxedScriptRunner: basic execution

    func testSandboxedRunnerExitZero() async throws {
        try requireStableLinuxSandboxRunner()
        let script = try writeScript("#!/bin/sh\nexit 0")
        let runner = SandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 5)
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertFalse(output.timedOut)
    }

    func testSandboxedRunnerExitOne() async throws {
        try requireStableLinuxSandboxRunner()
        let script = try writeScript("#!/bin/sh\nexit 1")
        let runner = SandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 5)
        XCTAssertEqual(output.exitCode, 1)
        XCTAssertFalse(output.timedOut)
    }

    func testSandboxedRunnerCapturesStdout() async throws {
        try requireStableLinuxSandboxRunner()
        let script = try writeScript("#!/bin/sh\necho 'sandbox out'\nexit 0")
        let runner = SandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 5)
        XCTAssertTrue(output.stdout.contains("sandbox out"))
    }

    func testSandboxedRunnerCapturesStderr() async throws {
        try requireStableLinuxSandboxRunner()
        let script = try writeScript("#!/bin/sh\necho 'sandbox err' >&2\nexit 0")
        let runner = SandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 5)
        XCTAssertTrue(output.stderr.contains("sandbox err"))
    }

    func testSandboxedRunnerTimesOut() async throws {
        try requireStableLinuxSandboxRunner()
        let script = try writeScript("#!/bin/sh\nsleep 60\nexit 0")
        let runner = SandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 1)
        XCTAssertTrue(output.timedOut, "Sandboxed script sleeping 60s should time out with 1s limit")
        XCTAssertEqual(output.exitCode, -1)
        XCTAssertLessThan(output.executionTimeMs, 10_000, "Sandboxed timeout should not wait for child processes to exit naturally")
    }

#if os(Linux)
    func testSandboxedRunnerTimeoutReapsBackgroundChildProcess() async throws {
        let script = try writeScript("""
        #!/bin/sh
        sleep 60 &
        wait
        """)
        let runner = SandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 1)
        XCTAssertTrue(output.timedOut, "Sandboxed script with a background child should still time out")
        XCTAssertEqual(output.exitCode, -1)
        XCTAssertLessThan(
            output.executionTimeMs,
            10_000,
            "Sandboxed timeout should reap background children without leaving pipes open"
        )
    }
#endif

    func testSandboxedRunnerWorkDir() async throws {
        try requireStableLinuxSandboxRunner()
        let script = try writeScript("#!/bin/sh\ntouch sandboxmarker.txt\nexit 0")
        let runner = SandboxedScriptRunner()
        _ = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 5)
        let markerPath = tmpDir.appendingPathComponent("sandboxmarker.txt").path
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: markerPath),
            "Sandboxed script should be able to write files in the working directory"
        )
    }

    // MARK: - SandboxedScriptRunner: network isolation

    func testSandboxedRunnerBlocksNetworkAccess() async throws {
        try requireStableLinuxSandboxRunner()
        // Write a script that tries to reach an external host.
        // In a sandboxed network namespace this should fail (exit non-zero from python).
        // The script exits 0 only if the connection SUCCEEDS — so we assert exit != 0.
        let script = try writeScript("""
        #!/bin/sh
        python3 -c "
        import socket, sys
        s = socket.socket()
        s.settimeout(2)
        try:
            s.connect(('8.8.8.8', 53))
            sys.exit(0)
        except OSError:
            sys.exit(1)
        "
        """)
        let runner = SandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 10)
        XCTAssertNotEqual(
            output.exitCode, 0,
            "Sandboxed runner should block outbound network access (exit 0 means connection succeeded)"
        )
    }

    // MARK: - Worker secret resolution

    func testResolveWorkerSharedSecretPrefersCLISecret() throws {
        _ = try writeSecretFile("file-secret")
        let resolved = resolveWorkerSharedSecret(
            cliWorkerSecret: " cli-secret ",
            environment: ["RUNNER_SHARED_SECRET": "env-secret"]
        )

        XCTAssertEqual(resolved, "cli-secret")
    }

    func testResolveWorkerSharedSecretUsesEnvSecretBeforeFile() throws {
        _ = try writeSecretFile("file-secret")
        let resolved = resolveWorkerSharedSecret(
            cliWorkerSecret: nil,
            environment: ["RUNNER_SHARED_SECRET": "env-secret"]
        )

        XCTAssertEqual(resolved, "env-secret")
    }

    func testResolveWorkerSharedSecretUsesDefaultFileWhenSecretsUnset() throws {
        let previous = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(tmpDir.path))
        defer { XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(previous)) }

        _ = try writeSecretFile("shared-file-secret\n")
        let resolved = resolveWorkerSharedSecret(
            cliWorkerSecret: nil,
            environment: [:]
        )

        XCTAssertEqual(resolved, "shared-file-secret")
    }

    func testDefaultWorkerSecretFilePathsIncludesCurrentDirectoryFileFirst() throws {
        let previous = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(tmpDir.path))
        defer { XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(previous)) }

        let paths = defaultWorkerSecretFilePaths()
        let expectedFirstPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".worker-secret")
            .path

        XCTAssertEqual(paths.first, expectedFirstPath)
        XCTAssertTrue(paths.contains("/data/.worker-secret"))
    }

    func testResolveWorkerSharedSecretReturnsNilWhenAllSourcesMissing() {
        let emptyDir = tmpDir.appendingPathComponent("empty", isDirectory: true)
        try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let previous = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(emptyDir.path))
        defer { XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(previous)) }

        let resolved = resolveWorkerSharedSecret(
            cliWorkerSecret: nil,
            environment: [:]
        )

        XCTAssertNil(resolved)
    }

    // MARK: - ScriptInvocation: R extension

    func testScriptInvocationRExtensionUsesRscript() {
        let url = URL(fileURLWithPath: "/tmp/test.r")
        let inv = scriptInvocation(for: url)
        XCTAssertEqual(inv.executableURL, URL(fileURLWithPath: "/usr/bin/env"))
        XCTAssertEqual(inv.arguments, ["Rscript", "/tmp/test.r"])
    }

    // MARK: - R runtime helpers

    private func rscriptAvailable() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["Rscript", "--version"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    private func writeRRuntime() throws {
        let url = tmpDir.appendingPathComponent("test_runtime.R")
        try testRuntimeR.write(to: url, atomically: true, encoding: .utf8)
    }

    func testRRuntimePassedExitsZeroWithJSON() async throws {
        try XCTSkipUnless(rscriptAvailable(), "Rscript not available")
        try writeRRuntime()
        let script = try writeScript(
            "source('test_runtime.R')\npassed('all good')",
            name: "test.r"
        )
        let runner = UnsandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 10)
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertTrue(output.stdout.contains("all good"), "stdout should contain the passed message")
        XCTAssertTrue(output.stdout.contains("shortResult"), "stdout should contain shortResult JSON key")
    }

    func testRRuntimeFailedExitsOneWithJSON() async throws {
        try XCTSkipUnless(rscriptAvailable(), "Rscript not available")
        try writeRRuntime()
        let script = try writeScript(
            "source('test_runtime.R')\nfailed('wrong answer')",
            name: "test.r"
        )
        let runner = UnsandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 10)
        XCTAssertEqual(output.exitCode, 1)
        XCTAssertTrue(output.stdout.contains("wrong answer"))
        XCTAssertTrue(output.stdout.contains("shortResult"))
    }

    func testRRuntimeErroredExitsTwoWithJSON() async throws {
        try XCTSkipUnless(rscriptAvailable(), "Rscript not available")
        try writeRRuntime()
        let script = try writeScript(
            "source('test_runtime.R')\nerrored('unexpected')",
            name: "test.r"
        )
        let runner = UnsandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 10)
        XCTAssertEqual(output.exitCode, 2)
        XCTAssertTrue(output.stdout.contains("unexpected"))
        XCTAssertTrue(output.stdout.contains("shortResult"))
    }

    func testRRuntimePassedDefaultMessage() async throws {
        try XCTSkipUnless(rscriptAvailable(), "Rscript not available")
        try writeRRuntime()
        let script = try writeScript(
            "source('test_runtime.R')\npassed()",
            name: "test.r"
        )
        let runner = UnsandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: tmpDir, timeLimitSeconds: 10)
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertTrue(output.stdout.contains("passed"), "default passed() message should be 'passed'")
    }

    // MARK: - ExponentialBackoff

    func testBackoffResetsToInitial() {
        var backoff = ExponentialBackoff(initial: .seconds(1), max: .seconds(64))
        for _ in 0..<5 { _ = backoff.next() }
        backoff.reset()
        // After reset the next jittered value must be <= 2s (double of the 1s initial).
        let afterReset = backoff.next()
        XCTAssertLessThanOrEqual(
            afterReset.components.seconds, 2,
            "After reset, next delay should be at most 2s"
        )
    }

    func testBackoffRespectsMaximum() {
        var backoff = ExponentialBackoff(initial: .seconds(1), max: .seconds(4))
        for _ in 0..<20 { _ = backoff.next() }
        let capped = backoff.next()
        XCTAssertLessThanOrEqual(
            capped.components.seconds, 4,
            "Backoff should never exceed max"
        )
    }

    // MARK: - extractNotebooksToCode

    @discardableResult
    private func writeNotebook(_ json: String, name: String = "assignment.ipynb") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testExtractPythonNotebookProducesPyFile() throws {
        let nb = """
        {
          "nbformat": 4,
          "metadata": {"kernelspec": {"name": "python3"}},
          "cells": [
            {"cell_type": "code", "source": ["def add(a, b):\\n", "    return a + b"]},
            {"cell_type": "markdown", "source": ["# ignored"]},
            {"cell_type": "code", "source": ["result = add(1, 2)"]}
          ]
        }
        """
        try writeNotebook(nb)
        try extractNotebooksToCode(in: tmpDir)

        let pyURL = tmpDir.appendingPathComponent("assignment.py")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pyURL.path),
                      "Should produce assignment.py from assignment.ipynb")

        let content = try String(contentsOf: pyURL, encoding: .utf8)
        XCTAssertTrue(content.contains("def add(a, b):"),
                      "Code cell content should be present")
        XCTAssertTrue(content.contains("result = add(1, 2)"),
                      "Second code cell should be present")
        XCTAssertFalse(content.contains("# ignored"),
                       "Markdown cells must not appear in output")
    }

    func testExtractRNotebookWithIRKernelProducesRFile() throws {
        let nb = """
        {
          "nbformat": 4,
          "metadata": {"kernelspec": {"name": "ir"}},
          "cells": [
            {"cell_type": "code", "source": ["x <- 42"]}
          ]
        }
        """
        try writeNotebook(nb)
        try extractNotebooksToCode(in: tmpDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("assignment.R").path),
                      "IR kernel should produce .R file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("assignment.py").path),
                       "IR kernel must NOT produce .py file")

        let content = try String(contentsOf: tmpDir.appendingPathComponent("assignment.R"), encoding: .utf8)
        XCTAssertTrue(content.contains("x <- 42"))
    }

    func testExtractRNotebookWithWebRKernelProducesRFile() throws {
        let nb = """
        {
          "nbformat": 4,
          "metadata": {"kernelspec": {"name": "webr"}},
          "cells": [{"cell_type": "code", "source": ["y <- 1"]}]
        }
        """
        try writeNotebook(nb)
        try extractNotebooksToCode(in: tmpDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("assignment.R").path),
                      "WebR kernel should produce .R file")
    }

    func testExtractPythonNotebookDetectsViaLanguageInfo() throws {
        // No kernelspec, but language_info says python → should produce .py
        let nb = """
        {
          "nbformat": 4,
          "metadata": {"language_info": {"name": "python"}},
          "cells": [{"cell_type": "code", "source": ["pass"]}]
        }
        """
        try writeNotebook(nb)
        try extractNotebooksToCode(in: tmpDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("assignment.py").path))
    }

    func testExtractSkipsEmptyCodeCells() throws {
        let nb = """
        {
          "nbformat": 4,
          "metadata": {},
          "cells": [
            {"cell_type": "code", "source": [""]},
            {"cell_type": "code", "source": ["   \\n  "]},
            {"cell_type": "code", "source": ["x = 1"]}
          ]
        }
        """
        try writeNotebook(nb)
        try extractNotebooksToCode(in: tmpDir)

        let content = try String(contentsOf: tmpDir.appendingPathComponent("assignment.py"), encoding: .utf8)
        // Only "x = 1" should be present; empty/whitespace cells are skipped.
        XCTAssertTrue(content.contains("x = 1"))
        // The file should not have multiple blank-line groups from empty cells.
        let codeLines = content.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces) == "" }
        // Allow at most a few blank lines (one between cells + header gap).
        XCTAssertLessThan(codeLines.count, 5, "Excess blank lines from empty cells")
    }

    func testExtractIgnoresNonNotebookFiles() throws {
        // Put a Python file and a non-notebook file in the dir; neither should be modified.
        let pyURL = tmpDir.appendingPathComponent("helper.py")
        try "original = True".write(to: pyURL, atomically: true, encoding: .utf8)
        let txtURL = tmpDir.appendingPathComponent("readme.txt")
        try "hello".write(to: txtURL, atomically: true, encoding: .utf8)

        try extractNotebooksToCode(in: tmpDir)  // no .ipynb → nothing to do

        let pyContent = try String(contentsOf: pyURL, encoding: .utf8)
        XCTAssertEqual(pyContent, "original = True", "Non-notebook files must be untouched")
    }

    func testExtractMultipleNotebooks() throws {
        // Two notebooks in the same directory → two output files.
        let nb = """
        {"nbformat":4,"metadata":{},"cells":[{"cell_type":"code","source":["pass"]}]}
        """
        try writeNotebook(nb, name: "lab1.ipynb")
        try writeNotebook(nb, name: "lab2.ipynb")
        try extractNotebooksToCode(in: tmpDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("lab1.py").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("lab2.py").path))
    }

    func testExtractSourceAsStringNotArray() throws {
        // The Jupyter spec allows source to be a plain string, not just array-of-strings.
        let nb = """
        {
          "nbformat": 4,
          "metadata": {},
          "cells": [{"cell_type": "code", "source": "x = 99"}]
        }
        """
        try writeNotebook(nb)
        try extractNotebooksToCode(in: tmpDir)

        let content = try String(contentsOf: tmpDir.appendingPathComponent("assignment.py"), encoding: .utf8)
        XCTAssertTrue(content.contains("x = 99"), "String-form source must be extracted")
    }

    func testClassifyHTTPRetryTreatsGatewayErrorsAsRetryable() {
        XCTAssertEqual(
            classifyHTTPRetry(statusCode: 503, body: "unavailable"),
            .retryable("HTTP 503: unavailable")
        )
        XCTAssertEqual(
            classifyHTTPRetry(statusCode: 502, body: "bad gateway"),
            .retryable("HTTP 502: bad gateway")
        )
    }

    func testClassifyHTTPRetryTreatsAuthAndConflictAsTerminal() {
        XCTAssertEqual(
            classifyHTTPRetry(statusCode: 401, body: "unauthorized"),
            .terminal("HTTP 401: unauthorized")
        )
        XCTAssertEqual(
            classifyHTTPRetry(statusCode: 409, body: "duplicate"),
            .terminal("HTTP 409: duplicate")
        )
    }
}
