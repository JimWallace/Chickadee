// Worker/RunnerLogCapture.swift
//
// A test seam for the runner's structured logs. They go to stderr, where no
// test can read them, so a mutation that deleted a log call was invisible to
// the whole suite (#1574) -- including the connection events an operator is
// told to watch for in docs/operational-diagnostics.md. With a capture bound,
// `writeToStandardError` appends here instead.

import Foundation
import Synchronization

/// Collects the runner's log lines in place of stderr, for a test that asks
/// which events a call emitted. Bound through `RunnerLogCapture.current`, so
/// only the task that binds it (and the tasks it starts) is captured, and
/// tests running in parallel never see each other's lines.
final class RunnerLogCapture: Sendable {
    @TaskLocal static var current: RunnerLogCapture?

    private let lines = Mutex<[String]>([])

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    /// Every line captured so far, in order.
    var capturedLines: [String] {
        lines.withLock { $0 }
    }

    /// The `event` of every captured line, in order.
    var events: [String] {
        capturedLines.compactMap { line in
            (try? JSONDecoder().decode(EventField.self, from: Data(line.utf8)))?.event
        }
    }
}

/// The one field of a structured log line that `events` reads.
private struct EventField: Decodable {
    let event: String
}
