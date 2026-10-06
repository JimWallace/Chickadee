// Tests/WorkerTests/SandboxCapabilityTests.swift
//
// #2268: the sandbox prelude runs as root of a new user namespace, which owns
// its mount namespace, so it holds every capability there and none of its
// mounts is locked. The test script used to keep those capabilities, so it
// could `umount` the covers (the work root, the private /tmp, the /dev/null
// over a hidden script) and read another job's directory. These tests prove
// that the script now starts with no capability, that each unmount fails, and
// that a sibling job's file stays unreadable.

import ChickadeeTestSupport
import Foundation
import Testing

@testable import chickadee_runner

#if os(Linux)
@Suite(.timeLimit(.minutes(2))) final class SandboxCapabilityTests {

    /// A work root with two job directories, as the runner lays them out.
    private let workRoot: URL
    private let ownJob: URL
    private let otherJob: URL

    init() throws {
        workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-sandbox-caps-\(UUID().uuidString)", isDirectory: true)
        ownJob = workRoot.appendingPathComponent("chickadee_ts_own_\(UUID().uuidString)", isDirectory: true)
        otherJob = workRoot.appendingPathComponent("chickadee_other_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ownJob, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherJob, withIntermediateDirectories: true)
        try "another student's work".write(
            to: otherJob.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try "a secret test".write(
            to: ownJob.appendingPathComponent("secrettest_hidden.sh"), atomically: true, encoding: .utf8)
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

    @Test(.requiresSandbox) func theScriptStartsWithNoCapability() async throws {
        let script = try writeScript(
            """
            #!/bin/sh
            grep -E '^Cap(Inh|Prm|Eff|Bnd|Amb):' /proc/self/status
            """)
        let output = await SandboxedScriptRunner().run(script: script, workDir: ownJob, timeLimitSeconds: 30)
        #expect(output.exitCode == 0, "stderr: \(output.stderr)")
        let lines = output.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 5, "stdout: \(output.stdout)")
        for line in lines {
            #expect(line.hasSuffix("0000000000000000"), "a capability remains: \(line)")
        }
    }

    @Test(.requiresSandbox) func theScriptCannotUnmountACoverAndReadAnotherJob() async throws {
        let hidden = ownJob.appendingPathComponent("secrettest_hidden.sh")
        let script = try writeScript(
            """
            #!/bin/sh
            cd /
            for target in "\(hidden.path)" "\(ownJob.path)" "\(workRoot.path)" /tmp; do
                if umount -l "$target" 2>/dev/null; then echo "unmounted $target"; fi
            done
            if cat "\(otherJob.path)/secret.txt" 2>/dev/null; then echo " <- read"; fi
            if grep -q "a secret test" "\(hidden.path)" 2>/dev/null; then echo "hidden script read"; fi
            exit 0
            """)
        let output = await SandboxedScriptRunner().run(
            script: script, workDir: ownJob, timeLimitSeconds: 30, env: [:], hiding: [hidden])
        #expect(output.exitCode == 0, "stderr: \(output.stderr)")
        #expect(!output.stdout.contains("unmounted"), "stdout: \(output.stdout)")
        #expect(!output.stdout.contains("another student's work"))
        #expect(!output.stdout.contains("hidden script read"))
    }
}
#endif
