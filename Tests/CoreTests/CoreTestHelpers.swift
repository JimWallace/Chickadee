// Tests/CoreTests/CoreTestHelpers.swift
//
// Core-test-side helpers.  See the WorkerTests/Support equivalent for
// the same idea; we duplicate because each test target is its own
// Swift module and CoreTests has no shared `Support/` folder yet.

import Foundation

/// Build a `URL` from a fixture string that's known-valid at the call site.
/// `URL(string:)` returns Optional because the parser must allow for
/// malformed input from real callers; in test fixtures the string is a
/// literal we control, so a nil result means the literal itself is wrong
/// and the test is unrunnable.  Hard-failing here keeps test files free
/// of per-line force-unwrap noise.
func testURL(_ string: String, file: StaticString = #file, line: UInt = #line) -> URL {
    guard let url = URL(string: string) else {
        fatalError("Malformed test URL literal: \(string)", file: file, line: line)
    }
    return url
}
