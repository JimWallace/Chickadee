// APIServer/Utilities/InFilterChunking.swift
//
// One chunk size for every `~~` (SQL IN) filter whose list can grow with the
// data (#2764).

/// The most values one `~~` (SQL IN) filter binds. Each value is one bind
/// parameter. PostgreSQL allows 65,535 per statement, and the SQLite that
/// sqlite-nio compiles sets `SQLITE_MAX_VARIABLE_NUMBER` to 250,000, so 5,000
/// leaves room on both for the other parameters in the same statement.
let inFilterChunkSize = 5_000

/// Splits the operand of a `~~` (SQL IN) filter into chunks of at most
/// `inFilterChunkSize` values, so the query stays under the driver's
/// bind-parameter limit however large the list grows. Run one query per chunk.
///
/// Use it for any list whose size follows the data: submission IDs, result
/// IDs, student IDs. An empty list gives no chunks, so the caller runs no query.
func chunkedForInFilter<T>(_ items: [T]) -> [[T]] {
    guard items.count > inFilterChunkSize else {
        return items.isEmpty ? [] : [items]
    }
    return stride(from: 0, to: items.count, by: inFilterChunkSize).map {
        Array(items[$0..<min($0 + inFilterChunkSize, items.count)])
    }
}
