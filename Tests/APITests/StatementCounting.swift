// Tests/APITests/StatementCounting.swift
//
// Counts the SQL statements one request sends. The test app's requests log
// through `app.logger`, and the Postgres driver logs each statement there at
// debug as "Executing query" with the SQL text. Only events that carry a
// `request-id` are counted, so a statement from a fixture or from a sweep
// running beside the request is not.

import Foundation
import Logging
import Synchronization
import Vapor

/// The statements logged while a `StatementCounter` was installed.
final class StatementLog: Sendable {
    // A LogHandler is a value type copied into each Logger, so the shared
    // store sits behind a reference the handler captures.
    private let statements = Mutex<[String]>([])

    fileprivate func append(_ sql: String) {
        statements.withLock { $0.append(sql) }
    }

    var all: [String] { statements.withLock { $0 } }

    func reset() {
        statements.withLock { $0.removeAll() }
    }
}

private struct StatementCountingLogHandler: LogHandler {
    let log: StatementLog
    let next: Logger

    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .debug

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        if event.message.description == "Executing query", metadata["request-id"] != nil,
            case .string(let sql)? = event.metadata?["sql"]
        {
            log.append(sql)
        }
        // Everything at the app's own level still reaches its handler.
        if event.level >= next.logLevel {
            next.log(
                level: event.level, event.message, metadata: event.metadata, source: event.source,
                file: event.file, function: event.function, line: event.line)
        }
    }
}

extension Application {
    /// Replaces `logger` with one that records each request's SQL in `log`,
    /// and passes every event at the old level on to the old logger.
    func countStatements(into log: StatementLog) {
        let next = logger
        logger = Logger(label: next.label) { _ in StatementCountingLogHandler(log: log, next: next) }
        logger.logLevel = .debug
    }
}
