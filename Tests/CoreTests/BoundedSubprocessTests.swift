// Tests/CoreTests/BoundedSubprocessTests.swift
//
// `runBounded` replaced three hand-written copies (#1792), so its contract is
// pinned here once: output and exit code come back, a signal reads as
// `128 + signal`, the deadline returns nil and takes the child's whole
// process group down, an `.only` environment is all the child sees, and a
// stream past the cap throws.

import Core
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct BoundedSubprocessTests {

    private static let limits = BoundedRunLimits(
        timeout: .seconds(10), outputLimit: 64 * 1024, teardownGrace: .milliseconds(200))

    private static func shell(
        _ script: String, environment: [String: String]? = nil, limits: BoundedRunLimits = limits
    ) async throws -> BoundedRunResult? {
        try await runBounded(
            executable: "/bin/sh", arguments: ["-c", script], environment: environment, limits: limits)
    }

    @Test func returnsOutputAndTheExitCode() async throws {
        let run = try #require(try await Self.shell("echo out; echo err >&2; exit 3"))
        #expect(run.standardOutput == "out\n")
        #expect(run.standardError == "err\n")
        #expect(run.exitCode == 3)
    }

    @Test func aSignalReadsAsOneHundredTwentyEightPlusTheSignal() async throws {
        let run = try #require(try await Self.shell("kill -9 $$"))
        #expect(run.exitCode == 128 + 9)
    }

    /// The deadline returns nil, and the teardown reaches what the child put
    /// in the background: the marker file the background job would write
    /// after the deadline never appears.
    @Test func theDeadlineReturnsNilAndEndsTheProcessGroup() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-bounded-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let started = ContinuousClock.now
        let run = try await Self.shell(
            "(sleep 2; touch '\(marker.path)') & sleep 30",
            limits: BoundedRunLimits(timeout: .milliseconds(300), outputLimit: 1024, teardownGrace: .milliseconds(200)))
        #expect(run == nil)
        #expect(ContinuousClock.now - started < .seconds(10), "the run outlived its deadline")
        try await Task.sleep(for: .seconds(3))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "a background child survived the teardown")
    }

    @Test func anOnlyEnvironmentIsAllTheChildSees() async throws {
        let run = try #require(
            try await Self.shell("env", environment: ["PATH": "/usr/bin:/bin", "CK_ONLY": "yes"]))
        let names = Set(run.standardOutput.split(separator: "\n").compactMap { $0.split(separator: "=").first })
        #expect(names.contains("CK_ONLY"))
        #expect(!names.contains("HOME"), "the parent environment leaked into an .only child")
    }

    @Test func outputPastTheCapThrows() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await Self.shell(
                "head -c 4096 /dev/zero",
                limits: BoundedRunLimits(timeout: .seconds(10), outputLimit: 1024, teardownGrace: .milliseconds(200)))
        }
    }
}
