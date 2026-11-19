// Tests/APITests/Performance/StatementCounter.swift
//
// Counts the SQL statements one request sends. Every statement, a Fluent
// query or a raw SQLKit one, passes through PostgresKit's SQL database, which
// logs it as "Executing query" with an `sql` metadata key on the logger of the
// database it runs on. A request's `req.db` runs on `req.logger`, so a handler
// on that logger sees every statement the request sends, and nothing that
// another request or a background sweep sends.
//
// `StatementCountingMiddleware` puts that handler on each request's logger.
// It records only while a test has armed it, so the fixture setup and the
// sign-in requests before the measured one are not counted.

import Logging
import Synchronization
import Vapor

/// The statements of the measured request, in the order they ran.
final class StatementRecorder: Sendable {
    private let state = Mutex<(armed: Bool, statements: [String])>((false, []))

    /// Starts a fresh recording.
    func arm() {
        state.withLock { $0 = (true, []) }
    }

    /// Stops recording and returns what was recorded.
    func disarm() -> [String] {
        state.withLock { current in
            current.armed = false
            return current.statements
        }
    }

    func record(_ sql: String) {
        state.withLock { current in
            if current.armed { current.statements.append(sql) }
        }
    }
}

/// Passes every message to the request's own handler, and records each SQL
/// statement on the way.
struct StatementCountingLogHandler: LogHandler {
    var inner: any LogHandler
    let recorder: StatementRecorder

    /// The PostgresKit message for one statement.
    static let statementMessage = "Executing query"

    var metadataProvider: Logger.MetadataProvider? {
        get { inner.metadataProvider }
        set { inner.metadataProvider = newValue }
    }

    var metadata: Logger.Metadata {
        get { inner.metadata }
        set { inner.metadata = newValue }
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { inner[metadataKey: key] }
        set { inner[metadataKey: key] = newValue }
    }

    /// Low enough that the debug-level statement messages reach `log(event:)`.
    /// The inner handler still gets only what its own level admits.
    var logLevel: Logger.Level {
        get { min(inner.logLevel, .debug) }
        set { inner.logLevel = newValue }
    }

    func log(event: LogEvent) {
        if event.message.description == Self.statementMessage,
            case .string(let sql)? = event.metadata?["sql"]
        {
            recorder.record(sql)
        }
        if event.level >= inner.logLevel {
            inner.log(event: event)
        }
    }
}

/// Wraps each request's logger in a `StatementCountingLogHandler`. Install it
/// at the beginning of the chain, before the first middleware that reads the
/// database.
struct StatementCountingMiddleware: AsyncMiddleware {
    let recorder: StatementRecorder

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        request.logger.handler = StatementCountingLogHandler(
            inner: request.logger.handler, recorder: recorder)
        return try await next.respond(to: request)
    }
}
