import Core
import Foundation
import RunnerCore
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(3))) final class WorkerTests {

    // MARK: - Setup

    private let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-worker-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    deinit {
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

    /// Returns true if the sandboxed runner is stable enough to run on
    /// the current host.  Linux containerized GitHub runners are
    /// excluded; callers should guard-return when this is false.
    private func sandboxedRunnerSupported() -> Bool {
        #if os(Linux)
        if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" {
            return false
        }
        #endif
        return true
    }

    // MARK: - UnsandboxedScriptRunner: exit code mapping

    @Test func scriptExitZeroReportsExitCodeZero() async throws {
        let script = try writeScript("#!/bin/sh\nexit 0")
        let runner = UnsandboxedScriptRunner()
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        #expect(output.exitCode == 0)
        #expect(output.timedOut == false)
    }

    @Test func scriptExitOneReportsExitCodeOne() async throws {
        let script = try writeScript("#!/bin/sh\nexit 1")
        let runner = UnsandboxedScriptRunner()
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        #expect(output.exitCode == 1)
        #expect(output.timedOut == false)
    }

    @Test func scriptExitTwoReportsExitCodeTwo() async throws {
        let script = try writeScript("#!/bin/sh\nexit 2")
        let runner = UnsandboxedScriptRunner()
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        #expect(output.exitCode == 2)
        #expect(output.timedOut == false)
    }

    // MARK: - UnsandboxedScriptRunner: output capture

    @Test func stdoutIsCaptured() async throws {
        let script = try writeScript("#!/bin/sh\necho 'hello world'\nexit 0")
        let runner = UnsandboxedScriptRunner()
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        #expect(output.stdout.contains("hello world"))
    }

    @Test func stderrIsCaptured() async throws {
        let script = try writeScript("#!/bin/sh\necho 'oops' >&2\nexit 0")
        let runner = UnsandboxedScriptRunner()
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        #expect(output.stderr.contains("oops"))
    }

    @Test func stdoutAndStderrAreSeparate() async throws {
        let script = try writeScript("#!/bin/sh\necho 'out'\necho 'err' >&2\nexit 0")
        let runner = UnsandboxedScriptRunner()
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        #expect(output.stdout.contains("out"))
        #expect(output.stdout.contains("err") == false)
        #expect(output.stderr.contains("err"))
        #expect(output.stderr.contains("out") == false)
    }

    // MARK: - UnsandboxedScriptRunner: env passthrough (Phase 1, issue #461)

    @Test func scriptReceivesEnvVarFromRunner() async throws {
        let script = try writeScript(
            """
            #!/bin/sh
            echo "seed=$CHICKADEE_ASSIGNMENT_SEED" >&2
            exit 0
            """)
        let runner = UnsandboxedScriptRunner()
        let workDir = tmpDir
        // `runner.run` reads `ProcessInfo.processInfo.environment` (walking the
        // C `environ` array) to build the child env. Run it under the env lock
        // so a concurrent `unsetenv` in another test can't mutate `environ`
        // mid-read.
        let output = try await withEnvLock {
            await runScriptRobustly(
                runner,
                script: script,
                workDir: workDir,
                timeLimitSeconds: 60,
                env: ["CHICKADEE_ASSIGNMENT_SEED": "deadbeef" + String(repeating: "c0ffee", count: 9) + "ba"]
            )
        }
        #expect(output.exitCode == 0)
        #expect(
            output.stderr.contains("seed=deadbeef"),
            "Expected env var to reach subprocess stderr; got: \(output.stderr)"
        )
    }

    @Test func scriptEnvVarUnsetWhenNoOverride() async throws {
        // Sanity check: empty env override = no var set. The script prints the
        // raw env-var expansion; an unset var expands to an empty string.
        let script = try writeScript(
            """
            #!/bin/sh
            echo "seed=[$CHICKADEE_ASSIGNMENT_SEED]" >&2
            exit 0
            """)
        let runner = UnsandboxedScriptRunner()
        let workDir = tmpDir
        // Mutating + reading `environ` runs under the env lock so it never
        // overlaps another env-touching test; the prior value is restored on
        // exit rather than left cleared.
        let output = try await withEnvLock {
            let original = ProcessInfo.processInfo.environment["CHICKADEE_ASSIGNMENT_SEED"]
            defer {
                if let original {
                    setenv("CHICKADEE_ASSIGNMENT_SEED", original, 1)
                } else {
                    unsetenv("CHICKADEE_ASSIGNMENT_SEED")
                }
            }
            // Ensure parent doesn't have the var set in this test's environment.
            unsetenv("CHICKADEE_ASSIGNMENT_SEED")
            return await runScriptRobustly(
                runner,
                script: script,
                workDir: workDir,
                timeLimitSeconds: 60,
                env: [:]
            )
        }
        #expect(output.exitCode == 0)
        #expect(
            output.stderr.contains("seed=[]"),
            "Expected unset env var when overrides is empty and parent didn't set it; got: \(output.stderr)"
        )
    }

    @Test func scriptDoesNotInheritNonAllowlistedParentEnv() async throws {
        // Regression test for the pre-#1139-fix Linux path, which applied the
        // allowlisted env via setenv() on top of the child's *inherited* full
        // parent environment — so non-allowlisted worker vars (the shape
        // RUNNER_SHARED_SECRET arrives in) leaked into student scripts.
        // execve() with a parent-built envp replaces the environment outright.
        let script = try writeScript(
            """
            #!/bin/sh
            echo "canary=[$WORKER_SECRET_CANARY]" >&2
            exit 0
            """)
        let runner = UnsandboxedScriptRunner()
        let workDir = tmpDir
        let output = try await withEnvLock {
            let original = ProcessInfo.processInfo.environment["WORKER_SECRET_CANARY"]
            defer {
                if let original {
                    setenv("WORKER_SECRET_CANARY", original, 1)
                } else {
                    unsetenv("WORKER_SECRET_CANARY")
                }
            }
            setenv("WORKER_SECRET_CANARY", "leaked-worker-secret", 1)
            return await runScriptRobustly(
                runner,
                script: script,
                workDir: workDir,
                timeLimitSeconds: 60,
                env: [:]
            )
        }
        #expect(output.exitCode == 0)
        #expect(
            output.stderr.contains("canary=[]"),
            "Non-allowlisted parent env vars must not reach the script; got: \(output.stderr)"
        )
    }

    // MARK: - UnsandboxedScriptRunner: timeout

    @Test func scriptTimesOut() async throws {
        let script = try writeScript("#!/bin/sh\nsleep 60\nexit 0")
        let runner = UnsandboxedScriptRunner()
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 1)
        #expect(output.timedOut, "Script sleeping 60s should time out with a 1s limit")
        #expect(output.exitCode == -1)
        #expect(output.executionTimeMs < 30_000)
    }

    #if os(Linux)
    @Test func scriptTimeoutReapsBackgroundChildProcess() async throws {
        let script = try writeScript(
            """
            #!/bin/sh
            sleep 60 &
            wait
            """)
        let runner = UnsandboxedScriptRunner()
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 1)
        #expect(output.timedOut, "Timed-out script with a background child should still time out")
        #expect(output.exitCode == -1)
        #expect(
            output.executionTimeMs < 30_000,
            "Timed-out script should reap inherited stdout/stderr handles from background children")
    }
    #endif

    // MARK: - UnsandboxedScriptRunner: working directory

    @Test func workDirIsSetCorrectly() async throws {
        let script = try writeScript("#!/bin/sh\ntouch marker.txt\nexit 0")
        let runner = UnsandboxedScriptRunner()
        _ = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        let markerPath = tmpDir.appendingPathComponent("marker.txt").path
        #expect(
            FileManager.default.fileExists(atPath: markerPath),
            "Script should create marker.txt in the supplied working directory"
        )
    }

    // MARK: - SandboxedScriptRunner: basic execution

    @Test func sandboxedRunnerExitZero() async throws {
        guard sandboxedRunnerSupported() else { return }
        let script = try writeScript("#!/bin/sh\nexit 0")
        let runner = SandboxedScriptRunner()
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        #expect(output.exitCode == 0)
        #expect(output.timedOut == false)
    }

    @Test func sandboxedRunnerExitOne() async throws {
        guard sandboxedRunnerSupported() else { return }
        let script = try writeScript("#!/bin/sh\nexit 1")
        let runner = SandboxedScriptRunner()
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        #expect(output.exitCode == 1)
        #expect(output.timedOut == false)
    }

    @Test func sandboxedRunnerCapturesStdout() async throws {
        guard sandboxedRunnerSupported() else { return }
        let script = try writeScript("#!/bin/sh\necho 'sandbox out'\nexit 0")
        let runner = SandboxedScriptRunner()
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        #expect(output.stdout.contains("sandbox out"))
    }

    @Test func sandboxedRunnerCapturesStderr() async throws {
        guard sandboxedRunnerSupported() else { return }
        let script = try writeScript("#!/bin/sh\necho 'sandbox err' >&2\nexit 0")
        let runner = SandboxedScriptRunner()
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        #expect(output.stderr.contains("sandbox err"))
    }

    @Test func sandboxedRunnerTimesOut() async throws {
        guard sandboxedRunnerSupported() else { return }
        let script = try writeScript("#!/bin/sh\nsleep 60\nexit 0")
        let runner = SandboxedScriptRunner()
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 1)
        #expect(output.timedOut, "Sandboxed script sleeping 60s should time out with 1s limit")
        #expect(output.exitCode == -1)
        #expect(
            output.executionTimeMs < 30_000, "Sandboxed timeout should not wait for child processes to exit naturally")
    }

    #if os(Linux)
    @Test func sandboxedRunnerTimeoutReapsBackgroundChildProcess() async throws {
        let script = try writeScript(
            """
            #!/bin/sh
            sleep 60 &
            wait
            """)
        let runner = SandboxedScriptRunner()
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 1)
        #expect(output.timedOut, "Sandboxed script with a background child should still time out")
        #expect(output.exitCode == -1)
        #expect(
            output.executionTimeMs < 30_000,
            "Sandboxed timeout should reap background children without leaving pipes open")
    }
    #endif

    @Test func sandboxedRunnerWorkDir() async throws {
        guard sandboxedRunnerSupported() else { return }
        let script = try writeScript("#!/bin/sh\ntouch sandboxmarker.txt\nexit 0")
        let runner = SandboxedScriptRunner()
        _ = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        let markerPath = tmpDir.appendingPathComponent("sandboxmarker.txt").path
        #expect(
            FileManager.default.fileExists(atPath: markerPath),
            "Sandboxed script should be able to write files in the working directory"
        )
    }

    // MARK: - SandboxedScriptRunner: network isolation

    @Test func sandboxedRunnerBlocksNetworkAccess() async throws {
        guard sandboxedRunnerSupported() else { return }
        // Write a script that tries to reach an external host.
        // In a sandboxed network namespace this should fail (exit non-zero from python).
        // The script exits 0 only if the connection SUCCEEDS — so we assert exit != 0.
        let script = try writeScript(
            """
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
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        #expect(
            output.exitCode != 0,
            "Sandboxed runner should block outbound network access (exit 0 means connection succeeded)")
    }

    // MARK: - Worker secret resolution

    @Test func resolveWorkerSharedSecretPrefersCLISecret() throws {
        _ = try writeSecretFile("file-secret")
        let resolved = resolveWorkerSharedSecret(
            cliWorkerSecret: " cli-secret ",
            environment: ["RUNNER_SHARED_SECRET": "env-secret"]
        )

        #expect(resolved == "cli-secret")
    }

    @Test func resolveWorkerSharedSecretUsesEnvSecretBeforeFile() throws {
        _ = try writeSecretFile("file-secret")
        let resolved = resolveWorkerSharedSecret(
            cliWorkerSecret: nil,
            environment: ["RUNNER_SHARED_SECRET": "env-secret"]
        )

        #expect(resolved == "env-secret")
    }

    // These three resolve against an explicit `currentDirectory` rather than
    // calling `changeCurrentDirectoryPath`: the working directory is
    // process-global, so a chdir here raced every concurrently running test
    // that resolves relative paths (and the chdir tests raced each other).

    @Test func resolveWorkerSharedSecretUsesDefaultFileWhenSecretsUnset() throws {
        _ = try writeSecretFile("shared-file-secret\n")
        let resolved = resolveWorkerSharedSecret(
            cliWorkerSecret: nil,
            environment: [:],
            currentDirectory: tmpDir.path
        )

        #expect(resolved == "shared-file-secret")
    }

    @Test func defaultWorkerSecretFilePathsIncludesCurrentDirectoryFileFirst() throws {
        let paths = defaultWorkerSecretFilePaths(currentDirectory: tmpDir.path)
        let expectedFirstPath =
            tmpDir
            .appendingPathComponent(".worker-secret")
            .path

        #expect(paths.first == expectedFirstPath)
        #expect(paths.contains("/data/.worker-secret"))
    }

    @Test func resolveWorkerSharedSecretReturnsNilWhenAllSourcesMissing() {
        let emptyDir = tmpDir.appendingPathComponent("empty", isDirectory: true)
        try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        let resolved = resolveWorkerSharedSecret(
            cliWorkerSecret: nil,
            environment: [:],
            currentDirectory: emptyDir.path
        )

        #expect(resolved == nil)
    }

    // MARK: - ScriptInvocation: R extension

    @Test func scriptInvocationRExtensionUsesRscript() {
        let url = URL(fileURLWithPath: "/tmp/test.r")
        let inv = scriptInvocation(for: url)
        #expect(inv.executableURL == URL(fileURLWithPath: "/usr/bin/env"))
        #expect(inv.arguments == ["Rscript", "/tmp/test.r"])
    }

    // MARK: - R runtime helpers

    private func rscriptAvailable() async -> Bool {
        // Probed via `runProcessRobustly` so the availability check can't
        // join the suite's fork storm under parallel CI load, and a transient
        // spawn failure (posix_spawn EAGAIN) is retried instead of silently
        // mis-reporting Rscript as unavailable.
        let proc = try? await runProcessRobustly {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["Rscript", "--version"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            return proc
        }
        guard let proc else { return false }
        return proc.terminationStatus == 0
    }

    private func writeRRuntime() throws {
        let url = tmpDir.appendingPathComponent("test_runtime.R")
        try testRuntimeR.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func rRuntimePassedExitsZeroWithJSON() async throws {
        guard await rscriptAvailable() else { return }
        try writeRRuntime()
        let script = try writeScript(
            "source('test_runtime.R')\npassed('all good')",
            name: "test.r"
        )
        let runner = UnsandboxedScriptRunner()
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        #expect(output.exitCode == 0)
        #expect(output.stdout.contains("all good"), "stdout should contain the passed message")
        #expect(output.stdout.contains("shortResult"), "stdout should contain shortResult JSON key")
    }

    @Test func rRuntimeFailedExitsOneWithJSON() async throws {
        guard await rscriptAvailable() else { return }
        try writeRRuntime()
        let script = try writeScript(
            "source('test_runtime.R')\nfailed('wrong answer')",
            name: "test.r"
        )
        let runner = UnsandboxedScriptRunner()
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        #expect(output.exitCode == 1)
        #expect(output.stdout.contains("wrong answer"))
        #expect(output.stdout.contains("shortResult"))
    }

    @Test func rRuntimeErroredExitsTwoWithJSON() async throws {
        guard await rscriptAvailable() else { return }
        try writeRRuntime()
        let script = try writeScript(
            "source('test_runtime.R')\nerrored('unexpected')",
            name: "test.r"
        )
        let runner = UnsandboxedScriptRunner()
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        #expect(output.exitCode == 2)
        #expect(output.stdout.contains("unexpected"))
        #expect(output.stdout.contains("shortResult"))
    }

    @Test func rRuntimePassedDefaultMessage() async throws {
        guard await rscriptAvailable() else { return }
        try writeRRuntime()
        let script = try writeScript(
            "source('test_runtime.R')\npassed()",
            name: "test.r"
        )
        let runner = UnsandboxedScriptRunner()
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        #expect(output.exitCode == 0)
        #expect(output.stdout.contains("passed"), "default passed() message should be 'passed'")
    }

    // MARK: - R runtime: locating the student's submission

    /// The reserved-filename list is interpolated from `AssignmentLanguage`, so
    /// the R runtime can't drift from the file the worker actually writes.
    @Test func rRuntimeReservesTheInputsFilename() {
        #expect(testRuntimeR.contains("\"\(AssignmentLanguage.r.inputsFileName)\""))
        #expect(testRuntimeR.contains("chickadee_student_file"))
    }

    /// The bug this closes: `_ck_inputs.R` is an R file in the grading
    /// workspace, so a helper that just scans `*.R` could grade Chickadee's own
    /// per-student inputs as the submission. It must never be a candidate — and
    /// with nothing else present there is simply nothing to grade.
    @Test func rRuntimeNeverGradesTheInputsFileAsTheSubmission() async throws {
        guard await rscriptAvailable() else { return }
        try writeRRuntime()
        try ".ck_inputs <- list(`x` = 1)\n".write(
            to: tmpDir.appendingPathComponent("_ck_inputs.R"), atomically: true, encoding: .utf8)

        let script = try writeScript(
            """
            source('test_runtime.R')
            f <- chickadee_student_file()
            if (!is.na(f)) failed(paste('picked a reserved file:', f))
            passed('no submission found, as expected')
            """,
            name: "test.r"
        )
        let runner = UnsandboxedScriptRunner()
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        #expect(output.exitCode == 0, "chickadee_student_file() must skip _ck_inputs.R")
    }

    /// Reserved files, the assignment's own helper, and test scripts are all
    /// skipped; `solution.R` wins when present (the validation path).
    @Test func rRuntimeFindsSubmissionAmongReservedFiles() async throws {
        guard await rscriptAvailable() else { return }
        try writeRRuntime()
        for (name, body) in [
            ("_ck_inputs.R", ".ck_inputs <- list()\n"),
            ("a2_helpers.R", "h <- function() 1\n"),
            ("publictest_thing.R", "# a test\n"),
            ("analysis.R", "f <- function() 1\n"),
            ("solution.R", "g <- function() 2\n"),
        ] {
            try body.write(
                to: tmpDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let script = try writeScript(
            """
            source('test_runtime.R')
            f <- chickadee_student_file(c('a2_helpers.R'))
            if (!identical(f, 'solution.R')) failed(paste('expected solution.R, got', f))
            passed('solution.R selected')
            """,
            name: "test.r"
        )
        let runner = UnsandboxedScriptRunner()
        let output = await runScriptRobustly(runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        #expect(output.exitCode == 0, "\(output.stdout)")
    }

    /// A `.chickadee_student_module` hint naming a real R file wins; a stale
    /// hint (the pre-fix `.py` name, or a file that was never written) must
    /// fall back to scanning rather than leaving nothing to grade.
    @Test func rRuntimeHonoursHintAndIgnoresStaleOnes() async throws {
        guard await rscriptAvailable() else { return }
        try writeRRuntime()
        try "u <- 1\n".write(
            to: tmpDir.appendingPathComponent("utils.R"), atomically: true, encoding: .utf8)
        try "f <- function() 1\n".write(
            to: tmpDir.appendingPathComponent("analysis.R"), atomically: true, encoding: .utf8)
        let hint = tmpDir.appendingPathComponent(".chickadee_student_module")

        try "utils.R".write(to: hint, atomically: true, encoding: .utf8)
        var script = try writeScript(
            """
            source('test_runtime.R')
            f <- chickadee_student_file()
            if (!identical(f, 'utils.R')) failed(paste('hint ignored, got', f))
            passed('hint honoured')
            """,
            name: "test.r"
        )
        let runner = UnsandboxedScriptRunner()
        var output = await runScriptRobustly(
            runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        #expect(output.exitCode == 0, "\(output.stdout)")

        // Stale `.py` hint — what an R job produced before the language-aware fix.
        try "analysis.py".write(to: hint, atomically: true, encoding: .utf8)
        script = try writeScript(
            """
            source('test_runtime.R')
            f <- chickadee_student_file()
            if (is.na(f)) failed('stale hint left nothing to grade')
            passed(paste('fell back to', f))
            """,
            name: "test.r"
        )
        output = await runScriptRobustly(
            runner, script: script, workDir: tmpDir, timeLimitSeconds: 60)
        #expect(output.exitCode == 0, "\(output.stdout)")
    }

    // MARK: - Student-module hint filename

    /// A notebook is extracted to its assignment's source language, so an R
    /// job's hint has to name the `.R` file. Naming `.py` (the pre-fix
    /// behaviour) pointed at a path that was never written.
    @Test func preferredStudentModuleFilenameIsLanguageAware() {
        #expect(
            preferredStudentModuleFilename(submissionFilename: "analysis.ipynb")
                == "analysis.py")
        #expect(
            preferredStudentModuleFilename(
                submissionFilename: "analysis.ipynb", language: .python) == "analysis.py")
        #expect(
            preferredStudentModuleFilename(submissionFilename: "analysis.ipynb", language: .r)
                == "analysis.R")
        // A source upload is already the module, whatever the assignment's language.
        #expect(
            preferredStudentModuleFilename(submissionFilename: "warmup.py") == "warmup.py")
        #expect(
            preferredStudentModuleFilename(submissionFilename: "warmup.R", language: .r)
                == "warmup.R")
        #expect(preferredStudentModuleFilename(submissionFilename: "data.csv") == nil)
        #expect(preferredStudentModuleFilename(submissionFilename: nil) == nil)
    }

    // MARK: - ExponentialBackoff

    @Test func backoffResetsToInitial() {
        var backoff = ExponentialBackoff(initial: .seconds(1), max: .seconds(64))
        for _ in 0..<5 { _ = backoff.next() }
        backoff.reset()
        // After reset the next jittered value must be <= 2s (double of the 1s initial).
        let afterReset = backoff.next()
        #expect(afterReset.components.seconds <= 2, "After reset, next delay should be at most 2s")
    }

    @Test func backoffRespectsMaximum() {
        var backoff = ExponentialBackoff(initial: .seconds(1), max: .seconds(4))
        for _ in 0..<20 { _ = backoff.next() }
        let capped = backoff.next()
        #expect(capped.components.seconds <= 4, "Backoff should never exceed max")
    }

    // MARK: - extractNotebooksToCode

    @discardableResult
    private func writeNotebook(_ json: String, name: String = "assignment.ipynb") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func extractPythonNotebookProducesPyFile() throws {
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
        #expect(
            FileManager.default.fileExists(atPath: pyURL.path),
            "Should produce assignment.py from assignment.ipynb")

        let content = try String(contentsOf: pyURL, encoding: .utf8)
        #expect(
            content.contains("def add(a, b):"),
            "Code cell content should be present")
        #expect(
            content.contains("result = add(1, 2)"),
            "Second code cell should be present")
        #expect(content.contains("# ignored") == false, "Markdown cells must not appear in output")
    }

    @Test func extractRNotebookWithIRKernelProducesRFile() throws {
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

        #expect(
            FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("assignment.R").path),
            "IR kernel should produce .R file")
        #expect(
            FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("assignment.py").path) == false,
            "IR kernel must NOT produce .py file")

        let content = try String(contentsOf: tmpDir.appendingPathComponent("assignment.R"), encoding: .utf8)
        #expect(content.contains("x <- 42"))
    }

    @Test func extractRNotebookWithWebRKernelProducesRFile() throws {
        let nb = """
            {
              "nbformat": 4,
              "metadata": {"kernelspec": {"name": "webr"}},
              "cells": [{"cell_type": "code", "source": ["y <- 1"]}]
            }
            """
        try writeNotebook(nb)
        try extractNotebooksToCode(in: tmpDir)

        #expect(
            FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("assignment.R").path),
            "WebR kernel should produce .R file")
    }

    @Test func extractRNotebookWithXeusRKernelProducesRFile() throws {
        let nb = """
            {
              "nbformat": 4,
              "metadata": {"kernelspec": {"name": "xr"}},
              "cells": [{"cell_type": "code", "source": ["z <- 2"]}]
            }
            """
        try writeNotebook(nb)
        try extractNotebooksToCode(in: tmpDir)

        #expect(
            FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("assignment.R").path),
            "xeus-r (xr) kernel should produce .R file")
    }

    @Test func extractPythonNotebookDetectsViaLanguageInfo() throws {
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

        #expect(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("assignment.py").path))
    }

    @Test func extractSkipsEmptyCodeCells() throws {
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
        #expect(content.contains("x = 1"))
        // The file should not have multiple blank-line groups from empty cells.
        let codeLines = content.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        // Allow at most a few blank lines (one between cells + header gap).
        #expect(codeLines.count < 5)
    }

    @Test func extractIgnoresNonNotebookFiles() throws {
        // Put a Python file and a non-notebook file in the dir; neither should be modified.
        let pyURL = tmpDir.appendingPathComponent("helper.py")
        try "original = True".write(to: pyURL, atomically: true, encoding: .utf8)
        let txtURL = tmpDir.appendingPathComponent("readme.txt")
        try "hello".write(to: txtURL, atomically: true, encoding: .utf8)

        try extractNotebooksToCode(in: tmpDir)  // no .ipynb → nothing to do

        let pyContent = try String(contentsOf: pyURL, encoding: .utf8)
        #expect(pyContent == "original = True", "Non-notebook files must be untouched")
    }

    @Test func extractMultipleNotebooks() throws {
        // Two notebooks in the same directory → two output files.
        let nb = """
            {"nbformat":4,"metadata":{},"cells":[{"cell_type":"code","source":["pass"]}]}
            """
        try writeNotebook(nb, name: "lab1.ipynb")
        try writeNotebook(nb, name: "lab2.ipynb")
        try extractNotebooksToCode(in: tmpDir)

        #expect(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("lab1.py").path))
        #expect(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("lab2.py").path))
    }

    @Test func extractSourceAsStringNotArray() throws {
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
        #expect(content.contains("x = 99"), "String-form source must be extracted")
    }

    @Test func classifyHTTPRetryTreatsGatewayErrorsAsRetryable() {
        #expect(classifyHTTPRetry(statusCode: 503, body: "unavailable") == .retryable("HTTP 503: unavailable"))
        #expect(classifyHTTPRetry(statusCode: 502, body: "bad gateway") == .retryable("HTTP 502: bad gateway"))
    }

    @Test func classifyHTTPRetryTreatsAuthAndConflictAsTerminal() {
        #expect(classifyHTTPRetry(statusCode: 401, body: "unauthorized") == .terminal("HTTP 401: unauthorized"))
        #expect(classifyHTTPRetry(statusCode: 409, body: "duplicate") == .terminal("HTTP 409: duplicate"))
    }
}
