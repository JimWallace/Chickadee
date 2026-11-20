// Tests/APITests/Notebooks/WorkingCopyLogCapture.swift
//
// A logger that keeps each warning it receives, for the working-copy tests.
// Several fallbacks in `NotebookWorkingCopyStore` only log: a failed
// substitution, a missing seed, a support file that cannot be linked. The
// log line is the one sign that the fallback ran, so the tests read it here.

import Foundation
import Logging
import Synchronization

final class WorkingCopyLogCapture: Sendable {
    private let stored = Mutex<[String]>([])

    /// A logger whose warnings (and worse) this capture keeps.
    var logger: Logger {
        Logger(label: "working-copy-log-capture.test") { _ in WorkingCopyCapturingLogHandler(sink: self) }
    }

    fileprivate func append(_ message: String) {
        stored.withLock { $0.append(message) }
    }

    /// The kept messages that contain `fragment`.
    func messages(containing fragment: String) -> [String] {
        stored.withLock { messages in messages.filter { $0.contains(fragment) } }
    }
}

private struct WorkingCopyCapturingLogHandler: LogHandler {
    let sink: WorkingCopyLogCapture

    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .warning

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        sink.append(event.message.description)
    }
}
