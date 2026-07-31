// APIServer/MCP/Admin/RingBufferLogHandler.swift
//
// A swift-log LogHandler that tees log records into the AdminEventSink so the
// admin query_logs tool can read recent events.  Multiplexed alongside Vapor's
// real ConsoleLogger in the logging bootstrap (runAPIServer), so console output
// is unchanged — this handler only observes.
//
// Two safeguards keep the buffer free of student data:
//   • Capture threshold: only warning+ records are kept (the actionable
//     diagnostic signal; routine info/observability stays out of the buffer and
//     is available via the metrics tools instead).
//   • Metadata redaction: known PII keys are dropped before an event is stored.
//     Free-text in the message itself can't be guaranteed clean, but warning+
//     server logs are infrastructure, not student content.

import Foundation
import Logging

struct RingBufferLogHandler: LogHandler {
    let label: String
    let sink: AdminEventSink

    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider?
    /// Only warning+ is captured.  As a handler in a MultiplexLogHandler, this
    /// bounds what the multiplex forwards here, so info/debug never reach the
    /// buffer; the in-`log` guard is belt-and-suspenders.
    var logLevel: Logger.Level = .warning

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        guard event.level >= .warning else { return }
        var merged = self.metadata
        if let provided = metadataProvider?.get() {
            merged.merge(provided) { _, new in new }
        }
        if let explicit = event.metadata {
            merged.merge(explicit) { _, new in new }
        }
        sink.record(
            CapturedEvent(
                timestamp: Date(),
                level: event.level.rawValue,
                label: label,
                message: event.message.description,
                metadata: Self.redact(merged)))
    }

    /// Metadata keys dropped before storage — anything that could identify a
    /// student.  Matched case-insensitively.  The write-side convention
    /// (enforced by `LogMessageHygieneTests`) is that identifiers go into
    /// metadata under one of these keys, never into message text, so dropping
    /// the key redacts the buffer while console logging keeps full fidelity.
    static let piiKeys: Set<String> = [
        "user_id", "userid", "submission_id", "submissionid", "username", "email",
        "actor_username", "student_id", "studentid", "name",
        "ip", "remote_ip", "org_defined_id", "user", "row_ids",
    ]

    static func redact(_ metadata: Logger.Metadata) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in metadata where !piiKeys.contains(key.lowercased()) {
            out[key] = value.description
        }
        return out
    }
}
