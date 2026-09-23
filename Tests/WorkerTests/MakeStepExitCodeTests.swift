// Tests/WorkerTests/MakeStepExitCodeTests.swift
//
// The pre-test `make` step fails the build exactly when `make` exits non-zero.
// The only `make` test in the suite is the hung-make timeout
// (`WorkerDaemonTests`), which never reaches the exit-code check, so the
// mutation sweep of 2026-09-22 (#1574) flipped `output.exitCode == 0` to `!=`
// and nothing failed: every good build would have been reported as failed,
// and every broken one graded.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) struct MakeStepExitCodeTests {

    /// `runMake` never touches the network, so the poller and reporter point
    /// at a port nothing listens on.
    private static func daemon() -> WorkerDaemon {
        let base = testURL("http://127.0.0.1:9")
        return WorkerDaemon(
            poller: JobPoller(
                apiBaseURL: base, workerID: "make-test", workerSecret: "secret", maxConcurrentJobs: 1,
                profile: nil),
            reporter: Reporter(apiBaseURL: base, workerID: "make-test", workerSecret: "secret"),
            runner: UnsandboxedScriptRunner(),
            apiBaseURL: base,
            workerID: "make-test",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            testSetupCache: TestSetupCache(
                cacheRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("make-test-cache-\(UUID().uuidString)")),
            config: .defaults
        )
    }

    private static func directory(makefile: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("make-exit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try makefile.write(to: dir.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test(.requiresMake) func aMakeThatExitsZeroSucceeds() async throws {
        let dir = try Self.directory(makefile: "all:\n\ttrue\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await Self.daemon().runMake(in: dir, target: nil)
    }

    @Test(.requiresMake) func aMakeThatExitsNonZeroFailsTheBuildWithItsOutput() async throws {
        let dir = try Self.directory(makefile: "all:\n\t@echo compile error here >&2\n\t@false\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try await Self.daemon().runMake(in: dir, target: nil)
            Issue.record("a failing make step must throw")
        } catch WorkerDaemonError.makeFailed(let target, let detail) {
            #expect(target == nil)
            #expect(detail?.contains("compile error here") == true)
        }
    }
}
