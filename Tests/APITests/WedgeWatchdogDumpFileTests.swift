// Tests/APITests/WedgeWatchdogDumpFileTests.swift
//
// The abort path also writes its thread table to a file (docs/ci-flakiness.md,
// Family 6): a stalled stderr pipe to `swift test` lost what the watchdog
// wrote there, so the CI lane prints this file on failure or cancel instead.
// Observed from outside the aborted process with an exit test, like
// `WedgeWatchdogAbortTests`, and it takes about as long (one 15 s monitor
// wake).

import ChickadeeTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(2))) struct WedgeWatchdogDumpFileTests {
    /// Fixed, because an exit test's body cannot capture a value from the
    /// parent. Only this test uses it.
    static let dumpDirectory = "/tmp/chickadee-wedge-dump-file-test"

    @Test func theAbortLeavesTheThreadTableInAFile() async throws {
        try? FileManager.default.removeItem(atPath: Self.dumpDirectory)
        try FileManager.default.createDirectory(atPath: Self.dumpDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: Self.dumpDirectory) }

        await #expect(processExitsWith: .signal(SIGABRT)) {
            // Both are read once, on first use, so they are set first.
            setenv("TMPDIR", WedgeWatchdogDumpFileTests.dumpDirectory, 1)
            setenv("CHICKADEE_WORKERTESTS_STALL_SECONDS", "1", 1)
            try await WedgeWatchdog.track {
                try await Task.sleep(for: .seconds(120))
            }
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: Self.dumpDirectory)
            .filter { $0.hasPrefix(WedgeWatchdog.dumpFilePrefix) }
        let file = try #require(files.first, "the abort wrote no dump file")
        let dump = try String(contentsOfFile: "\(Self.dumpDirectory)/\(file)", encoding: .utf8)
        #expect(dump.contains("Stall limit was 1s"))
        #expect(dump.contains("syscall="), "each thread row names the syscall it is blocked in")
    }
}
