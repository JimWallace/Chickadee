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
// The assertions read the descriptor table directly instead of spawning a
// child and inferring. `ScriptCapture` is internal, so a test can construct one
// and ask the kernel what its descriptors actually are: deterministic, fast,
// and it fails with the flag that is wrong rather than with a timeout.
//
// Linux-only, because it reads /proc/self/fd. Everywhere else it stands down
// silently -- the repo's "expected on this platform" idiom -- and the mutation
// sweep runs on Linux.
//
// Protocol: docs/mutation-triage.md -- SURVIVED confirmed before, KILLED after.

import Foundation
import Testing

@testable import chickadee_runner

#if canImport(Glibc)
import Glibc
#endif

@Suite(.serialized, .timeLimit(.minutes(3))) struct ScriptExecutionGapTests {

    /// Every PIPE descriptor the process currently holds.
    ///
    /// Filtered to pipes deliberately. Listing /proc/self/fd opens a directory
    /// descriptor that appears in its own listing, so an unfiltered snapshot
    /// reports that handle as a new descriptor -- which both hides a real pipe
    /// end (the count still reached four) and adds one that is legitimately not
    /// close-on-exec. A first cut of this file did exactly that and failed
    /// against correct code.
    private static func openPipeDescriptors() -> Set<Int32>? {
        #if os(Linux)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")
        else { return nil }
        return Set(
            entries.compactMap(Int32.init).filter { descriptor in
                let target =
                    (try? FileManager.default.destinationOfSymbolicLink(
                        atPath: "/proc/self/fd/\(descriptor)")) ?? ""
                return target.hasPrefix("pipe:")
            })
        #else
        return nil
        #endif
    }

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
    @Test func everyPipeEndIsCreatedCloseOnExec() throws {
        guard let before = Self.openPipeDescriptors() else { return }

        let capture = ScriptCapture()
        defer { capture.discard() }

        guard let after = Self.openPipeDescriptors() else { return }
        let created = after.subtracting(before)

        // Two pipes, two ends each. Asserted so that a future change to how
        // many streams are captured fails here loudly rather than quietly
        // reducing what the next expectation checks.
        #expect(created.count == 4, "expected 4 new descriptors, got \(created.sorted())")

        for descriptor in created.sorted() {
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
    /// walks into EMFILE.
    @Test func discardReleasesBothReadEnds() throws {
        guard let before = Self.openPipeDescriptors() else { return }

        let capture = ScriptCapture()

        guard let afterInit = Self.openPipeDescriptors() else { return }
        let created = afterInit.subtracting(before)
        try #require(created.count == 4, "expected 4 new descriptors, got \(created.sorted())")

        capture.discard()

        // discard() owns the READ ends only -- the write ends belong to
        // Subprocess from the moment they are handed over -- so exactly two of
        // the four must now be closed. Asserting the count rather than naming
        // which keeps this independent of the order makeStream() allocates in.
        let closed = created.filter { Self.isClosed($0) }
        let note =
            "discard() must release both read ends; closed \(closed.count) of "
            + "\(created.count) (\(created.sorted()))"
        #expect(closed.count == 2, "\(note)")
    }
}
