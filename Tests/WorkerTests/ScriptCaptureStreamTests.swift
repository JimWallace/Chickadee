// Tests/WorkerTests/ScriptCaptureStreamTests.swift
//
// `ScriptCapture` counts its two open streams. The mutation sweep of
// 2026-10-13 (#2535) inverted `streamsClosed` (`:393`) and nothing failed: it
// read true while both pipes were open, which makes the timeout path treat a
// running child as finished. The sibling survivor at `:483`, the signal on
// the last EOF, was already killed by the suite when it was verified, so it
// gets no test here.
//
// Protocol: docs/mutation-triage.md -- SURVIVED confirmed before, KILLED after.

import Foundation
import Testing

@testable import chickadee_runner

#if canImport(Glibc)
import Glibc
#endif

@Suite(.timeLimit(.minutes(2))) struct ScriptCaptureStreamTests {

    @Test func aFreshCaptureHasBothStreamsOpen() {
        let capture = ScriptCapture()
        defer {
            for descriptor in capture.descriptorsForTesting.writeEnds { close(descriptor) }
            capture.discard()
        }
        #expect(!capture.streamsClosed)
    }
}
