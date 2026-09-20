// Tests/TestSupport/TestURL.swift
//
// One definition for all three test targets. It used to be declared once in
// CoreTests and once in WorkerTests, identical to the character, because
// CoreTests had no shared support target to import.

import Foundation

/// Build a `URL` from a fixture string that's known-valid at the call site.
/// `URL(string:)` returns Optional because the parser must allow for
/// malformed input from real callers; in test fixtures the string is a
/// literal we control, so a nil result means the literal itself is wrong
/// and the test is unrunnable.  Hard-failing here keeps test files free
/// of per-line force-unwrap noise.
public func testURL(_ string: String, file: StaticString = #file, line: UInt = #line) -> URL {
    guard let url = URL(string: string) else {
        fatalError("Malformed test URL literal: \(string)", file: file, line: line)
    }
    return url
}
