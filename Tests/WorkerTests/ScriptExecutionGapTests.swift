// Tests/WorkerTests/ScriptExecutionGapTests.swift
//
// Closes mutation survivors in `Sources/Worker/ScriptExecution.swift` that sit
// on descriptor hygiene -- the close-on-exec flag every pipe end is created
// with, and the release of the read ends on the path where the child never
// launched.
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
// Protocol: docs/mutation-triage.md -- SURVIVED confirmed before, KILLED after.

import Foundation
import Testing

@testable import chickadee_runner

#if canImport(Glibc)
import Glibc
#endif

@Suite(.timeLimit(.minutes(3))) struct ScriptExecutionGapTests {

    private static func isCloseOnExec(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFD)
        return flags != -1 && (flags & FD_CLOEXEC) != 0
    }

    private static func isClosed(_ descriptor: Int32) -> Bool {
        fcntl(descriptor, F_GETFD) == -1
    }

    /// Survivors: `:337 RelationalOperatorReplacement` (`flags != -1` → `== -1`)
    /// and `:337 RemoveSideEffects` (deleting the `fcntl(F_SETFD)` outright).
    ///
    /// Either one produces pipe ends without `FD_CLOEXEC`. Nothing fails at the
    /// time; the cost lands later as an unrelated process holding a duplicate
    /// write end and a drain thread that never sees EOF.
    @Test func everyPipeEndIsCreatedCloseOnExec() {
        let capture = ScriptCapture()
        defer { capture.discard() }

        let (readEnds, writeEnds) = capture.descriptorsForTesting
        for descriptor in readEnds + writeEnds {
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

        for descriptor in readEnds {
            #expect(!Self.isClosed(descriptor), "read end \(descriptor) was closed before discard()")
        }

        capture.discard()

        for descriptor in readEnds {
            #expect(
                Self.isClosed(descriptor),
                "discard() left read end \(descriptor) open; a failed launch leaks it")
        }
    }
}
