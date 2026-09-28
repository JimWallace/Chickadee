// Tests/APITests/SupervisedProcessTests.swift
//
// The long-lived child behind the local-runner autostart: it reports whether
// the child still runs, stops it with an escalating teardown, appends both
// streams to a log, and gives the child only the environment it is handed.

import Foundation
import Subprocess
import SystemPackage
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(1))) final class SupervisedProcessTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervised-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private var logPath: FilePath { FilePath(directory.appendingPathComponent("child.log").path) }

    private func log() throws -> String {
        try String(contentsOfFile: logPath.string, encoding: .utf8)
    }

    /// Starts `/bin/sh -c script` and returns it with a stream that yields
    /// its one outcome.
    private func startShell(
        _ script: String,
        environment: [String: String] = ["PATH": "/usr/bin:/bin"],
        logPath: FilePath? = nil
    ) throws -> (SupervisedProcess, AsyncStream<SupervisedProcess.Outcome>) {
        let (outcomes, sink) = AsyncStream<SupervisedProcess.Outcome>.makeStream()
        let process = try SupervisedProcess.start(
            executable: "/bin/sh",
            arguments: ["-c", script],
            environment: environment,
            workingDirectory: FilePath(directory.path),
            logPath: logPath ?? self.logPath
        ) { outcome in
            sink.yield(outcome)
            sink.finish()
        }
        return (process, outcomes)
    }

    private static func first(_ outcomes: AsyncStream<SupervisedProcess.Outcome>) async throws -> TerminationStatus {
        var iterator = outcomes.makeAsyncIterator()
        let outcome = try #require(await iterator.next())
        return try outcome.get()
    }

    @Test func aChildThatExitsReportsItsStatusAndStopsRunning() async throws {
        let (process, outcomes) = try startShell("exit 3")

        #expect(try await Self.first(outcomes) == .exited(3))
        #expect(!process.isRunning)
    }

    @Test func stopEndsARunningChildWithSIGTERM() async throws {
        let (process, outcomes) = try startShell("exec sleep 60")
        #expect(process.isRunning)

        await process.stop()

        #expect(!process.isRunning)
        #expect(try await Self.first(outcomes) == .signaled(SIGTERM))
    }

    @Test func stopEscalatesWhenTheChildIgnoresTermAndInterrupt() async throws {
        let (process, outcomes) = try startShell("trap '' TERM INT; while :; do sleep 0.1; done")
        // The trap has to be in place before the first signal arrives.
        try await Task.sleep(for: .milliseconds(300))

        await process.stop()

        #expect(try await Self.first(outcomes) == .signaled(SIGKILL))
    }

    @Test func bothStreamsAreAppendedToTheLog() async throws {
        try "earlier line\n".write(toFile: logPath.string, atomically: true, encoding: .utf8)
        let (_, outcomes) = try startShell("echo to-stdout; echo to-stderr >&2")

        #expect(try await Self.first(outcomes) == .exited(0))
        #expect(try log() == "earlier line\nto-stdout\nto-stderr\n")
    }

    @Test func theChildGetsOnlyTheGivenEnvironment() async throws {
        let (_, outcomes) = try startShell(
            #"echo "given=$CK_GIVEN home=${HOME-unset}""#,
            environment: ["PATH": "/usr/bin:/bin", "CK_GIVEN": "yes"])

        #expect(try await Self.first(outcomes) == .exited(0))
        #expect(try log() == "given=yes home=unset\n")
    }

    @Test func aLogThatCannotBeOpenedDoesNotStopTheLaunch() async throws {
        let unreachable = FilePath(directory.appendingPathComponent("missing/dir/child.log").path)
        let (_, outcomes) = try startShell("exit 0", logPath: unreachable)

        #expect(try await Self.first(outcomes) == .exited(0))
    }

    @Test func aMissingExecutableReportsAFailure() async throws {
        let (outcomes, sink) = AsyncStream<SupervisedProcess.Outcome>.makeStream()
        let process = try SupervisedProcess.start(
            executable: FilePath(directory.appendingPathComponent("no-such-program").path),
            arguments: [],
            environment: [:],
            workingDirectory: FilePath(directory.path),
            logPath: logPath
        ) { outcome in
            sink.yield(outcome)
            sink.finish()
        }

        var iterator = outcomes.makeAsyncIterator()
        let outcome = try #require(await iterator.next())
        #expect(throws: (any Error).self) { try outcome.get() }
        #expect(!process.isRunning)
    }
}
