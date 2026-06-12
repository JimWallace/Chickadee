// Tests/WorkerTests/Support/WorkerTestSkip.swift
//
// Worker-test-side helpers: an IssueRecorded error for clean skips,
// a `withMockURLProtocolLock` actor-backed serializer for
// `MockURLProtocol`'s process-global state, and a `testURL` builder
// that centralizes the unavoidable force-unwrap of hardcoded test
// fixture URLs.

import Foundation

struct IssueRecorded: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

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

/// Serializes async test bodies that touch `MockURLProtocol`'s global
/// state.  `@Suite(.serialized)` is within-suite only; ReporterTests and
/// JobPollerTests are separate suites that share the same process-wide
/// stub queue and capture list.  Wrapping each touchy test body in
/// `withMockURLProtocolLock { ... }` forces them to run one at a time
/// across all suites.
func withMockURLProtocolLock<R: Sendable>(_ body: @Sendable () async throws -> R) async throws -> R {
    try await MockURLProtocolLock.shared.run(body)
}

private actor MockURLProtocolLock {
    static let shared = MockURLProtocolLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<R: Sendable>(_ body: @Sendable () async throws -> R) async throws -> R {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            locked = false
        }
    }
}
