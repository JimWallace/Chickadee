// Tests/WorkerTests/SandboxDiskLimitTests.swift
//
// #2251: every job directory on a runner lives on one shared mount, so one test
// script that wrote without bound in its working directory filled it, and every
// other job on the runner then failed to write. The sandbox now covers the
// working directory with an overlay: the script reads the job's files through
// it, and what it writes goes to a private tmpfs of `diskLimitMegabytes` that
// is discarded when the script ends. An opponent directory is read-only. These
// tests prove that a script that fills its space fails alone and leaves the job
// directory as it was, that a script beside it still writes, that the job's
// files stay readable and a program the script writes still runs, and that the
// opponent directory cannot be written.

import ChickadeeTestSupport
import Foundation
import Testing

@testable import chickadee_runner

@Suite struct JobDiskLimitFlagTests {

    @Test func theSandboxedRunnerTheFlagSelectsCarriesTheDiskLimit() throws {
        let choice = WorkerCommand.scriptRunner(sandboxed: true, diskLimitMegabytes: 42)
        let runner = try #require(choice.runner as? SandboxedScriptRunner)
        #expect(runner.diskLimitMegabytes == 42)
    }
}

#if os(Linux)
@Suite(.timeLimit(.minutes(2))) final class SandboxDiskLimitTests {

    /// A work root with two job directories and an opponent, as the runner lays
    /// them out.
    private let workRoot: URL
    private let ownJob: URL
    private let otherJob: URL
    private let opponent: URL

    init() throws {
        workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-sandbox-disk-\(UUID().uuidString)", isDirectory: true)
        ownJob = workRoot.appendingPathComponent("chickadee_ts_own_\(UUID().uuidString)", isDirectory: true)
        otherJob = workRoot.appendingPathComponent("chickadee_ts_other_\(UUID().uuidString)", isDirectory: true)
        opponent = workRoot.appendingPathComponent("chickadee_opponent_\(UUID().uuidString)", isDirectory: true)
        for directory in [ownJob, otherJob, opponent] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "the instructor's data\n".write(
            to: ownJob.appendingPathComponent("given.txt"), atomically: true, encoding: .utf8)
        try "a classmate's program\n".write(
            to: opponent.appendingPathComponent("opponent.txt"), atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: workRoot)
    }

    private func writeScript(_ body: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("test.sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: url.path)
        return url
    }

    @Test(.requiresSandbox) func aScriptThatFillsItsSpaceFailsAloneAndAScriptBesideItStillWrites() async throws {
        let filling = try writeScript(
            """
            #!/bin/sh
            dd if=/dev/zero of=big bs=1M count=20 2>&1 && echo "wrote everything"
            exit 0
            """, in: ownJob)
        let output = await SandboxedScriptRunner(diskLimitMegabytes: 4)
            .run(script: filling, workDir: ownJob, timeLimitSeconds: 30)
        #expect(output.stdout.contains("No space left"), "stdout: \(output.stdout) stderr: \(output.stderr)")
        #expect(!output.stdout.contains("wrote everything"))
        #expect(!FileManager.default.fileExists(atPath: ownJob.appendingPathComponent("big").path))

        let beside = try writeScript(
            """
            #!/bin/sh
            dd if=/dev/zero of=small bs=1M count=1 2>/dev/null && echo "wrote 1 MB"
            """, in: otherJob)
        let besideOutput = await SandboxedScriptRunner(diskLimitMegabytes: 4)
            .run(script: beside, workDir: otherJob, timeLimitSeconds: 30)
        #expect(besideOutput.exitCode == 0, "stderr: \(besideOutput.stderr)")
        #expect(besideOutput.stdout.contains("wrote 1 MB"))
    }

    @Test(.requiresSandbox) func theJobsFilesAreReadableAndTheScriptsWritesAreDiscarded() async throws {
        let script = try writeScript(
            """
            #!/bin/sh
            cat given.txt
            echo "changed" > given.txt
            echo "new" > new.txt
            cat given.txt new.txt
            """, in: ownJob)
        let output = await SandboxedScriptRunner().run(script: script, workDir: ownJob, timeLimitSeconds: 30)
        #expect(output.exitCode == 0, "stderr: \(output.stderr)")
        #expect(output.stdout.contains("the instructor's data"))
        #expect(output.stdout.contains("changed"))
        #expect(output.stdout.contains("new"))

        let given = try String(contentsOf: ownJob.appendingPathComponent("given.txt"), encoding: .utf8)
        #expect(given == "the instructor's data\n", "the script's change outlived it")
        #expect(!FileManager.default.fileExists(atPath: ownJob.appendingPathComponent("new.txt").path))
    }

    /// A C++ or Java test compiles into its working directory and runs what
    /// it built, so the private space must allow a program to run.
    @Test(.requiresSandbox) func aProgramTheScriptWritesInItsWorkingDirectoryRuns() async throws {
        let script = try writeScript(
            """
            #!/bin/sh
            printf '#!/bin/sh\\necho "built and ran"\\n' > built.sh
            chmod +x built.sh
            ./built.sh
            """, in: ownJob)
        let output = await SandboxedScriptRunner().run(script: script, workDir: ownJob, timeLimitSeconds: 30)
        #expect(output.exitCode == 0, "stderr: \(output.stderr)")
        #expect(output.stdout.contains("built and ran"))
    }

    @Test(.requiresSandbox) func theOpponentDirectoryIsReadableAndCannotBeWritten() async throws {
        let script = try writeScript(
            """
            #!/bin/sh
            cat "$CHICKADEE_OPPONENT_DIR/opponent.txt"
            if echo "changed" > "$CHICKADEE_OPPONENT_DIR/opponent.txt" 2>/dev/null; then echo "written"; fi
            """, in: ownJob)
        let output = await SandboxedScriptRunner().run(
            script: script, workDir: ownJob, timeLimitSeconds: 30, env: ["CHICKADEE_OPPONENT_DIR": opponent.path])
        #expect(output.exitCode == 0, "stderr: \(output.stderr)")
        #expect(output.stdout.contains("a classmate's program"))
        #expect(!output.stdout.contains("written"))
        let content = try String(contentsOf: opponent.appendingPathComponent("opponent.txt"), encoding: .utf8)
        #expect(content == "a classmate's program\n")
    }
}
#endif
