// Tests/APITests/LogCapture.swift
//
// The one capturing log handler for the API tests. Many paths under test only
// log: a fallback that ran, a write that failed, a sweep that skipped a
// course. The log line is the one sign that the path ran, so a test hands
// `CapturedLog.logger` to the code and reads the lines back here.

import Logging
import Synchronization

/// Keeps every line a test logger writes at `minimumLevel` or above, with its
/// level and its metadata (the handler's and the call's, the call's winning).
final class CapturedLog: Sendable {
    /// One logged line. Metadata values are kept as their descriptions.
    struct Record: Sendable, Equatable {
        let level: Logger.Level
        let message: String
        let metadata: [String: String]

        init(level: Logger.Level, message: String, metadata: [String: String] = [:]) {
            self.level = level
            self.message = message
            self.metadata = metadata
        }

        /// The `error` metadata value, if the line carried one.
        var error: String? { metadata["error"] }
    }

    private let minimumLevel: Logger.Level
    private let label: String
    private let stored = Mutex<[Record]>([])

    init(minimumLevel: Logger.Level = .trace, label: String = "captured-log.test") {
        self.minimumLevel = minimumLevel
        self.label = label
    }

    /// A logger whose lines at `minimumLevel` or above this capture keeps.
    var logger: Logger {
        Logger(label: label) { _ in CapturingLogHandler(sink: self, logLevel: minimumLevel) }
    }

    fileprivate func append(_ record: Record) {
        stored.withLock { $0.append(record) }
    }

    /// Every kept line, in the order it was logged.
    var records: [Record] { stored.withLock { $0 } }

    /// Every kept line rendered as `"<level> <message>"`.
    var lines: [String] { records.map { "\($0.level) \($0.message)" } }

    /// `lines` joined with newlines, for a search across the whole log.
    var allText: String { lines.joined(separator: "\n") }

    /// The messages that contain `fragment`.
    func messages(containing fragment: String) -> [String] {
        records.filter { $0.message.contains(fragment) }.map(\.message)
    }

    /// The messages at `level` that contain `fragment`.
    func messages(at level: Logger.Level, containing fragment: String) -> [String] {
        records.filter { $0.level == level && $0.message.contains(fragment) }.map(\.message)
    }

    /// Whether a line at `level` contains `fragment`.
    func contains(_ level: Logger.Level, _ fragment: String) -> Bool {
        records.contains { $0.level == level && $0.message.contains(fragment) }
    }

    /// The first line at `level` that contains `fragment`.
    func record(_ level: Logger.Level, containing fragment: String) -> Record? {
        records.first { $0.level == level && $0.message.contains(fragment) }
    }

    /// The one line whose message is exactly `message`, or nil when there is
    /// none or more than one.
    func single(message: String) -> Record? {
        let matches = records.filter { $0.message == message }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The lines whose message is exactly `message`.
    func matching(message: String) -> [Record] {
        records.filter { $0.message == message }
    }

    /// The lines whose `event` metadata value is `event`.
    func matching(event: String) -> [Record] {
        records.filter { $0.metadata["event"] == event }
    }

    /// Whether any metadata value of any line contains `text`.
    func anyMetadataValueContains(_ text: String) -> Bool {
        records.contains { $0.metadata.values.contains { $0.contains(text) } }
    }
}

/// A `LogHandler` is a value copied into the `Logger`, so the shared store
/// sits behind the `CapturedLog` reference the handler holds.
private struct CapturingLogHandler: LogHandler {
    let sink: CapturedLog

    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level

    init(sink: CapturedLog, logLevel: Logger.Level) {
        self.sink = sink
        self.logLevel = logLevel
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let merged = metadata.merging(event.metadata ?? [:]) { _, new in new }
        sink.append(
            CapturedLog.Record(
                level: event.level, message: event.message.description, metadata: merged.mapValues { "\($0)" }))
    }
}
