// Tests/WorkerTests/SandboxIsolationTests.swift
//
// With `--max-jobs` above 1, two jobs run on one runner as the same user, and
// every job directory is a child of one work root. Before #2061 a script in
// one job could read the other job's workspace, which holds another student's
// submission. The sandbox now covers the work root and binds back only the
// job's own directories. These tests prove that from inside a script: a
// sibling job directory is invisible, a directory the environment names is
// visible, and the script's own directory still works. /tmp and /dev/shm are
// private too: a file one job leaves there is invisible to the next, and a
// file a script writes there does not outlive it.

import ChickadeeTestSupport
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) final class SandboxIsolationTests {

    /// A work root with two job directories, as the runner lays them out.
    private let workRoot: URL
    private let ownJob: URL
    private let otherJob: URL

    init() throws {
        workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-sandbox-isolation-\(UUID().uuidString)", isDirectory: true)
        ownJob = workRoot.appendingPathComponent("chickadee_ts_own_\(UUID().uuidString)", isDirectory: true)
        otherJob = workRoot.appendingPathComponent("chickadee_other_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ownJob, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: otherJob.appendingPathComponent("opponent", isDirectory: true), withIntermediateDirectories: true)
        try "another student's work".write(
            to: otherJob.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try "a classmate's opponent".write(
            to: otherJob.appendingPathComponent("opponent/opponent.txt"), atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: workRoot)
    }

    private func writeScript(_ body: String) throws -> URL {
        let url = ownJob.appendingPathComponent("test.sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: url.path)
        return url
    }

    @Test(.requiresSandbox) func aSiblingJobDirectoryIsInvisible() async throws {
        let script = try writeScript(
            """
            #!/bin/sh
            if [ -e "\(otherJob.path)/secret.txt" ]; then echo "visible"; exit 1; fi
            ls "\(workRoot.path)"
            """)
        let runner = SandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: ownJob, timeLimitSeconds: 60)
        #expect(output.exitCode == 0, "stderr: \(output.stderr)")
        #expect(!output.stdout.contains("visible"))
        // The work root lists the job's own directory and nothing else.
        let listed = output.stdout.split(separator: "\n").map(String.init)
        #expect(listed == [ownJob.lastPathComponent], "work root listing: \(listed)")
    }

    @Test(.requiresSandbox) func aDirectoryTheEnvironmentNamesIsVisibleAndTheRestOfItsJobIsNot() async throws {
        let opponent = otherJob.appendingPathComponent("opponent", isDirectory: true)
        let script = try writeScript(
            """
            #!/bin/sh
            cat "$CHICKADEE_OPPONENT_DIR/opponent.txt" || exit 1
            if [ -e "\(otherJob.path)/secret.txt" ]; then echo "secret visible"; exit 1; fi
            """)
        let runner = SandboxedScriptRunner()
        let output = await runner.run(
            script: script, workDir: ownJob, timeLimitSeconds: 60,
            env: ["CHICKADEE_OPPONENT_DIR": opponent.path])
        #expect(output.exitCode == 0, "stderr: \(output.stderr)")
        #expect(output.stdout.contains("a classmate's opponent"))
        #expect(!output.stdout.contains("secret visible"))
    }

    @Test(.requiresSandbox) func theOwnDirectoryIsWritableAndKeepsItsPath() async throws {
        let script = try writeScript(
            """
            #!/bin/sh
            pwd
            echo written > marker.txt
            cat marker.txt
            """)
        let runner = SandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: ownJob, timeLimitSeconds: 60)
        #expect(output.exitCode == 0, "stderr: \(output.stderr)")
        #expect(output.stdout.contains(ownJob.standardizedFileURL.path))
        #expect(output.stdout.contains("written"))
        #expect(FileManager.default.fileExists(atPath: ownJob.appendingPathComponent("marker.txt").path))
    }

    @Test(.requiresSandbox) func aFileAnotherJobLeftInTmpIsInvisible() async throws {
        let leftover = URL(fileURLWithPath: "/tmp/chickadee-sandbox-leftover-\(UUID().uuidString)")
        try "another job's temporary file".write(to: leftover, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: leftover) }
        let script = try writeScript(
            """
            #!/bin/sh
            if [ -e "\(leftover.path)" ]; then echo "leftover visible"; exit 1; fi
            """)
        let runner = SandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: ownJob, timeLimitSeconds: 60)
        #expect(output.exitCode == 0, "stdout: \(output.stdout) stderr: \(output.stderr)")
    }

    @Test(.requiresSandbox) func aFileTheScriptWritesInTmpOrSharedMemoryDoesNotOutliveIt() async throws {
        let name = "chickadee-sandbox-written-\(UUID().uuidString)"
        let script = try writeScript(
            """
            #!/bin/sh
            echo written > "/tmp/\(name)" || exit 1
            if [ -d /dev/shm ]; then echo written > "/dev/shm/\(name)" || exit 1; fi
            """)
        let runner = SandboxedScriptRunner()
        let output = await runner.run(script: script, workDir: ownJob, timeLimitSeconds: 60)
        #expect(output.exitCode == 0, "stderr: \(output.stderr)")
        #expect(!FileManager.default.fileExists(atPath: "/tmp/\(name)"))
        #expect(!FileManager.default.fileExists(atPath: "/dev/shm/\(name)"))
    }

    @Test(.requiresSandbox) func aTmpdirUnderTmpStillWorks() async throws {
        let tmpdir = URL(fileURLWithPath: "/tmp/chickadee-sandbox-tmpdir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpdir) }
        let script = try writeScript(
            """
            #!/bin/sh
            file=$(mktemp) || exit 1
            echo "made $file"
            """)
        let runner = SandboxedScriptRunner()
        let output = await runner.run(
            script: script, workDir: ownJob, timeLimitSeconds: 60, env: ["TMPDIR": tmpdir.path])
        #expect(output.exitCode == 0, "stderr: \(output.stderr)")
        #expect(output.stdout.contains("made \(tmpdir.path)/"))
    }

    @Test(.requiresSandbox) func anotherSuiteScriptIsHiddenAndTheOwnScriptStillRuns() async throws {
        let other = ownJob.appendingPathComponent("secrettest_other.sh")
        try "echo the secret test\n".write(to: other, atomically: true, encoding: .utf8)
        let script = try writeScript(
            """
            #!/bin/sh
            if grep -q "the secret test" secrettest_other.sh 2>/dev/null; then echo "hidden script readable"; exit 1; fi
            echo own script ran
            """)
        let runner = SandboxedScriptRunner()
        let output = await runner.run(
            script: script, workDir: ownJob, timeLimitSeconds: 60, env: [:], hiding: [other])
        #expect(output.exitCode == 0, "stdout: \(output.stdout) stderr: \(output.stderr)")
        #expect(output.stdout.contains("own script ran"))
        // Hidden from the script only: the file itself is untouched.
        #expect(try String(contentsOf: other, encoding: .utf8) == "echo the secret test\n")
    }

    @Test(.requiresSandbox) func theProbeLeavesNothingBehind() async throws {
        let before = try FileManager.default.contentsOfDirectory(atPath: workRoot.path).sorted()
        let reason = await SandboxedScriptRunner.probe(workDir: workRoot)
        #expect(reason == nil)
        let after = try FileManager.default.contentsOfDirectory(atPath: workRoot.path).sorted()
        #expect(after == before)
    }

    @Test func theVisibleSetIsTheWorkingDirectoryPlusNamedDirectoriesUnderTheRoot() throws {
        let opponent = otherJob.appendingPathComponent("opponent", isDirectory: true)
        let elsewhere = FileManager.default.temporaryDirectory
        let visible = SandboxVisibleDirectories(
            workDir: ownJob,
            environment: [
                "CHICKADEE_OPPONENT_DIR": opponent.path,
                "CHICKADEE_MATCH_SEED": "deadbeef",
                "HOME": elsewhere.path,
                "A_FILE": otherJob.appendingPathComponent("secret.txt").path,
            ])
        #expect(visible.workRoot.standardizedFileURL == workRoot.standardizedFileURL)
        #expect(
            visible.directories.map(\.path) == [ownJob.standardizedFileURL.path, opponent.standardizedFileURL.path])
    }
}
