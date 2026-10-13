import SQLKit

/// One normalized statement from `pg_stat_statements`. Its text has a
/// placeholder in place of each constant, so it holds no value.
struct QueryStatementStat: Encodable, Sendable, Equatable {
    /// Postgres's hash of the normalized statement, as a string because it
    /// is a 64-bit value that JSON numbers cannot always hold.
    let queryID: String
    let query: String
    let calls: Int
    let totalMs: Double
    let meanMs: Double
    let maxMs: Double
    let rows: Int
    /// The share of reads served from the buffer cache, or nil when the
    /// statement read no blocks.
    let cacheHitPercent: Double?

    init(
        queryID: String, query: String, calls: Int, totalMs: Double, meanMs: Double, maxMs: Double,
        rows: Int, sharedBlocksHit: Int, sharedBlocksRead: Int
    ) {
        self.queryID = queryID
        self.query = query
        self.calls = calls
        self.totalMs = Self.rounded(totalMs)
        self.meanMs = Self.rounded(meanMs)
        self.maxMs = Self.rounded(maxMs)
        self.rows = rows
        let blocks = sharedBlocksHit + sharedBlocksRead
        self.cacheHitPercent = blocks > 0 ? Self.rounded(Double(sharedBlocksHit) / Double(blocks) * 100) : nil
    }

    init(row: any SQLRow) throws {
        self.init(
            queryID: String(try row.decode(column: "queryid", as: Int64.self)),
            query: try row.decode(column: "query", as: String.self),
            calls: Int(try row.decode(column: "calls", as: Int64.self)),
            totalMs: try row.decode(column: "total_exec_time", as: Double.self),
            meanMs: try row.decode(column: "mean_exec_time", as: Double.self),
            maxMs: try row.decode(column: "max_exec_time", as: Double.self),
            rows: Int(try row.decode(column: "rows", as: Int64.self)),
            sharedBlocksHit: Int(try row.decode(column: "shared_blks_hit", as: Int64.self)),
            sharedBlocksRead: Int(try row.decode(column: "shared_blks_read", as: Int64.self))
        )
    }

    /// Two decimals: enough for a millisecond figure, without float noise.
    static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
