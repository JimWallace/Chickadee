// Tests/WorkerTests/Support/WorkerTestSkip.swift
//
// Worker-test-side helpers: an IssueRecorded error for clean skips and
// a `withMockURLProtocolLock` actor-backed serializer for
// `MockURLProtocol`'s process-global state.

import Foundation

struct IssueRecorded: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
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
