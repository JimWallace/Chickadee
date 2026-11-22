// Tests/WorkerTests/Scripts/ScriptExecutionTests.swift
//
// `Sources/Worker/ScriptExecution.swift`: the launch-failure result, the 1 MB
// output cap in `CapturedPipeBuffer`, and descriptor hygiene -- the
// close-on-exec flag every pipe end is created with, and the release of the
// read ends on the path where the child never launched. The descriptor tests
// close mutation survivors; this suite was `ScriptExecutionGapTests` until the
// coverage sweep of 2026-11-21 added the first two groups.
//
// WHY THESE ARE WORTH A TEST RATHER THAN A SHRUG. Both defend the wedge class
// that issues #1233 and #1139 are about: a pipe end that survives an exec is
// inherited by an unrelated concurrently-spawned process, which postpones EOF
// on our read until THAT process exits, parking a cooperative-pool thread
// indefinitely. The failure is a hung CI job with no output, arriving days
// later and nowhere near this file -- so the guard has to be pinned where it is
// cheap to see, not left to a timing test that would be flaky anyway.
//
// THE FIRST CUT OF THIS FILE WAS ITSELF FLAKY, which is worth recording because
// the shape is inviting. It diffed /proc/self/fd around the allocation and
// asserted the four new descriptors were close-on-exec. That races every other
// suite in the process: Swift Testing runs suites in parallel, so a pipe opened
// elsewhere lands in the diff. Measured at 3 failures in 10 runs, reporting
// five and eight new descriptors where four were expected -- and it was briefly
// blamed on mutants in an unrelated file, since a flaky test reads as "killed"
// to the mutation verifier. It also quietly swept in the directory handle that
// listing /proc/self/fd opens, which appears in its own listing and is
// legitimately not close-on-exec.
//
// So the capture is asked for its own descriptors instead. Deterministic, and
// it fails naming the descriptor whose flag is wrong.
//
// THE SAME RACE CAME BACK IN `discardReleasesBothReadEnds`, one step later. It
// asked whether a descriptor NUMBER was closed after `discard()`, but the kernel
// hands a freed number to the next open in the process, so a pipe another suite
// opened in between made a correct `discard()` read as a leak (seen once in a
// WorkerTests x30 run, 2026-09-27). It now remembers which pipe each number
// named, and a number that names a different file afterwards counts as closed.
//
// Protocol: docs/mutation-triage.md -- SURVIVED confirmed before, KILLED after.

import Foundation
import RunnerCore
import SystemPackage
import Testing

@testable import chickadee_runner

#if canImport(Glibc)
import Glibc
#endif

@Suite(.timeLimit(.minutes(3))) struct ScriptExecutionTests {

    // MARK: - Launch failure

    /// A launch that cannot start is the contract's "error" (exit 2), never a
    /// timeout (-1): the doc comment on `executeScriptLaunch` promises that -1
    /// means exactly one thing. The prefix leads stderr so the student and the
    /// operator can tell which launch failed.
    @Test func aLaunchThatCannotStartIsAnErrorWithItsPrefix() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-exec-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let output = await executeScriptLaunch(
            ScriptLaunch(
                executablePath: workDir.appendingPathComponent("no-such-interpreter").path,
                arguments: [], env: ["PATH": "/usr/bin:/bin"]),
            workDir: workDir, timeLimitSeconds: 30, launchErrorPrefix: "Failed to launch test script")

        #expect(output.exitCode == 2)
        #expect(!output.timedOut)
        #expect(output.stdout.isEmpty)
        #expect(output.stderr.hasPrefix("Failed to launch test script: "), "stderr was \(output.stderr)")
    }

    // MARK: - The 1 MB output cap

    private static let limit = CapturedPipeBuffer.maxCapturedBytes
    private static let truncationMarker = "\n... output truncated (limit 1 MB) ...\n"

    /// A chunk that crosses the limit keeps the bytes up to the limit, then
    /// the marker. Dropping the partial prefix would lose the last lines a
    /// student printed before the cap, which are often the useful ones.
    @Test func aChunkThatCrossesTheLimitIsCutAtTheLimitAndMarked() {
        let buffer = CapturedPipeBuffer()
        buffer.append(Data(repeating: UInt8(ascii: "a"), count: Self.limit - 10))
        buffer.append(Data(repeating: UInt8(ascii: "b"), count: 20))

        let expected =
            String(repeating: "a", count: Self.limit - 10) + String(repeating: "b", count: 10)
            + Self.truncationMarker
        #expect(buffer.text() == expected)
    }

    /// Output that fills the limit exactly is not truncated, and the next byte
    /// adds only the marker.
    @Test func outputThatFillsTheLimitExactlyIsKeptWholeUntilOneMoreByte() {
        let buffer = CapturedPipeBuffer()
        buffer.append(Data(repeating: UInt8(ascii: "a"), count: Self.limit))
        #expect(buffer.text() == String(repeating: "a", count: Self.limit))

        buffer.append(Data("b".utf8))
        #expect(buffer.text() == String(repeating: "a", count: Self.limit) + Self.truncationMarker)
    }

    /// After the cut, later chunks are dropped and the marker appears once.
    @Test func chunksAfterTheCutAreDropped() {
        let buffer = CapturedPipeBuffer()
        buffer.append(Data(repeating: UInt8(ascii: "a"), count: Self.limit + 1))
        let afterCut = buffer.text()

        buffer.append(Data("more output".utf8))
        buffer.append(Data())
        #expect(buffer.text() == afterCut)
        #expect(afterCut.hasSuffix(Self.truncationMarker))
    }

    /// End to end: a script that prints more than the cap still finishes,
    /// because the drain keeps reading after the cut. If the drain stopped,
    /// the child would block on a full pipe and the run would time out.
    @Test func aScriptThatPrintsMoreThanTheCapFinishesWithTruncatedOutput() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-exec-cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let output = await executeScriptLaunch(
            ScriptLaunch(
                executablePath: "/bin/sh",
                arguments: ["-c", "head -c 3000000 /dev/zero | tr '\\0' a; echo done >&2"],
                env: ["PATH": "/usr/bin:/bin"]),
            workDir: workDir, timeLimitSeconds: 60, launchErrorPrefix: "Failed to launch test script")

        #expect(output.exitCode == 0)
        #expect(!output.timedOut)
        #expect(output.stdout == String(repeating: "a", count: Self.limit) + Self.truncationMarker)
        #expect(output.stderr == "done\n")
    }

    // MARK: - Descriptor hygiene

    private static func isCloseOnExec(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFD)
        return flags != -1 && (flags & FD_CLOEXEC) != 0
    }

    /// The file a descriptor refers to, or nil when the descriptor is closed.
    private static func fileIdentity(_ descriptor: Int32) -> FileIdentity? {
        guard let status = try? FileDescriptor(rawValue: descriptor).stat() else { return nil }
        return FileIdentity(device: UInt64(status.deviceID.rawValue), inode: UInt64(status.inode.rawValue))
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    /// Survivors: `:337 RelationalOperatorReplacement` (`flags != -1` → `== -1`)
    /// and `:337 RemoveSideEffects` (deleting the `fcntl(F_SETFD)` outright).
    ///
    /// Either one produces pipe ends without `FD_CLOEXEC`. Nothing fails at the
    /// time; the cost lands later as an unrelated process holding a duplicate
    /// write end and a drain thread that never sees EOF.
    ///
    /// On Darwin only the read ends are close-on-exec: there the write ends
    /// must stay inheritable for a `createSession` launch, and Subprocess's
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT` keeps them out of other children.
    @Test func everyPipeEndIsCreatedCloseOnExec() {
        let capture = ScriptCapture()
        defer { capture.discard() }

        let (readEnds, writeEnds) = capture.descriptorsForTesting
        #if canImport(Darwin)
        let closeOnExec = readEnds
        for descriptor in writeEnds {
            #expect(!Self.isCloseOnExec(descriptor), "write end \(descriptor) must be inheritable on Darwin")
        }
        #else
        let closeOnExec = readEnds + writeEnds
        #endif
        for descriptor in closeOnExec {
            let note =
                "descriptor \(descriptor) is not close-on-exec; it will survive an exec "
                + "into an unrelated child and postpone EOF (issues #1233 / #1139)"
            #expect(Self.isCloseOnExec(descriptor), "\(note)")
        }
    }

    /// Survivors: `:399` and `:400 RemoveSideEffects` — deleting
    /// `close(standardOutput.readEnd)` and `close(standardError.readEnd)` in
    /// `discard()`.
    ///
    /// `discard()` is the failed-launch path: no child started, so no drain
    /// thread will ever run and close these. Dropping either close leaks a
    /// descriptor per failed launch, and a runner that fails launches in a loop
    /// walks into EMFILE. Both ends are named individually so a mutant that
    /// removes one close fails on that one rather than on a count.
    @Test func discardReleasesBothReadEnds() {
        let capture = ScriptCapture()
        let (readEnds, _) = capture.descriptorsForTesting

        var pipes: [Int32: FileIdentity] = [:]
        for descriptor in readEnds {
            let identity = Self.fileIdentity(descriptor)
            #expect(identity != nil, "read end \(descriptor) was closed before discard()")
            pipes[descriptor] = identity
        }

        capture.discard()

        // Another suite may already have reopened the number; only the same
        // pipe under it would be a leak.
        for descriptor in readEnds {
            let identity = Self.fileIdentity(descriptor)
            #expect(
                identity == nil || identity != pipes[descriptor],
                "discard() left read end \(descriptor) open; a failed launch leaks it")
        }
    }
}
