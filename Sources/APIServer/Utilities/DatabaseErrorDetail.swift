// APIServer/Utilities/DatabaseErrorDetail.swift
//
// `PSQLError`'s `description` is deliberately generic ("Generic description to
// prevent accidental leakage of sensitive data"), so a log line built from
// `"\(error)"` says only that Postgres failed, never why. That hid a missing
// grant for the least-privilege MCP role behind every get_validation_result
// call. This reads the server's own message and SQLSTATE instead: the reason
// ("permission denied for table validation_variants") without the query text
// or bind values that `String(reflecting:)` would add.

import FluentPostgresDriver

enum DatabaseErrorDetail {
    /// A loggable one-line reason for `error`. Postgres errors give the
    /// server message and SQLSTATE code; every other error is described as is.
    static func describe(_ error: any Error) -> String {
        guard let psqlError = error as? PSQLError,
            let message = psqlError.serverInfo?[.message]
        else {
            return String(describing: error)
        }
        guard let code = psqlError.serverInfo?[.sqlState] else { return message }
        return "\(message) (SQLSTATE \(code))"
    }
}
