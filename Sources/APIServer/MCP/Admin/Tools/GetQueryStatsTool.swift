// APIServer/MCP/Admin/Tools/GetQueryStatsTool.swift
//
// Read tool: per-statement database timing from Postgres `pg_stat_statements`
// — calls, total / mean / max time, rows and buffer-cache hit rate for the
// top statements of this database. It answers "where does the database spend
// its time", which the request timings cannot: they measure a whole request.
//
// PII boundary: the tool returns only SELECT / INSERT / UPDATE / DELETE /
// MERGE statements, which Postgres stores normalized, with every constant
// replaced by a placeholder ($1, $2, ...). A utility statement keeps its
// literals, so it is filtered out (QueryStatistics.normalizedStatementFilter).
// The text is cut at QueryStatistics.maximumQueryLength.

import Core
import Fluent
import SQLKit
import Vapor

struct GetQueryStatsTool: DiagnosticTool {
    struct Input: Decodable, Sendable {
        /// "total" (default), "mean" or "calls".
        var orderBy: String?
        /// Max statements to return (default 15; clamped 1…50).
        var limit: Int?
    }

    struct Output: Encodable, Sendable {
        /// false when the statistics cannot be read; `note` says why.
        let available: Bool
        /// notPostgres | notPreloaded | extensionMissing | ready
        let state: String
        let note: String?
        let orderBy: String
        /// When Postgres last reset the statistics (Postgres 14 or later).
        /// The figures cover the time since then.
        let statsResetAt: Date?
        let totalCalls: Int?
        let totalExecMs: Double?
        let statements: [Statement]
    }

    struct Statement: Encodable, Sendable {
        let queryID: String
        let query: String
        let calls: Int
        let totalMs: Double
        let meanMs: Double
        let maxMs: Double
        let rows: Int
        let cacheHitPercent: Double?
        /// This statement's share of the total time of all statements.
        let shareOfTotalPercent: Double?

        init(_ stat: QueryStatementStat, totalExecMs: Double) {
            queryID = stat.queryID
            query = stat.query
            calls = stat.calls
            totalMs = stat.totalMs
            meanMs = stat.meanMs
            maxMs = stat.maxMs
            rows = stat.rows
            cacheHitPercent = stat.cacheHitPercent
            shareOfTotalPercent =
                totalExecMs > 0 ? QueryStatementStat.rounded(stat.totalMs / totalExecMs * 100) : nil
        }
    }

    static let name = "get_query_stats"
    static let limitBound = MCPBoundedInt(default: 15, max: 50)
    static let description =
        "Per-statement database timing from Postgres pg_stat_statements: for the top statements "
        + "of this database, the calls, total / mean / max time in ms, rows, buffer-cache hit "
        + "rate and share of total time, since the last statistics reset (statsResetAt). Order by "
        + "total time (where the database spends its time, the default), mean time (the slowest "
        + "single statements) or calls (the statements that run most often). Use it after "
        + "get_metrics_snapshot or get_request_metrics shows a slow route, to find the statement "
        + "behind it. Returns available=false with a note when the database is SQLite or the "
        + "extension is not loaded. Read-only; only SELECT/INSERT/UPDATE/DELETE/MERGE statements are "
        + "returned, which Postgres normalizes with every constant replaced by a placeholder."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "orderBy": .object([
                "type": .string("string"),
                "enum": .array(QueryStatisticsOrder.allCases.map { .string($0.rawValue) }),
                "description": .string("Sort key: total (default), mean or calls."),
            ]),
            "limit": Self.limitBound.property("Max statements"),
        ]),
        "additionalProperties": .bool(false),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        let order = try Self.resolveOrder(input.orderBy)
        let limit = Self.limitBound.resolve(input.limit)
        let db = context.request.db

        let availability = try await QueryStatistics.availability(on: db)
        guard availability == .ready, let sql = db as? (any SQLDatabase),
            let schema = try await QueryStatistics.extensionSchema(on: sql)
        else {
            return Output(
                available: false, state: availability.rawValue, note: availability.note,
                orderBy: order.rawValue, statsResetAt: nil, totalCalls: nil, totalExecMs: nil,
                statements: [])
        }

        let totals = try await QueryStatistics.totals(on: sql, schema: schema)
        let statements = try await QueryStatistics.topStatements(
            on: sql, schema: schema, orderedBy: order, limit: limit)
        let textIsHidden = statements.contains { $0.query == QueryStatistics.hiddenQueryText }
        return Output(
            available: true,
            state: availability.rawValue,
            note: textIsHidden
                ? "Some statement text is hidden: the database role cannot read statements that another "
                    + "role ran. Grant the role pg_read_all_stats to see them." : nil,
            orderBy: order.rawValue,
            statsResetAt: await QueryStatistics.statsResetAt(on: sql, schema: schema),
            totalCalls: totals.calls,
            totalExecMs: QueryStatementStat.rounded(totals.totalExecMs),
            statements: statements.map { Statement($0, totalExecMs: totals.totalExecMs) }
        )
    }

    static func resolveOrder(_ raw: String?) throws -> QueryStatisticsOrder {
        guard let raw else { return .total }
        guard let order = QueryStatisticsOrder(rawValue: raw) else {
            throw MCPToolError.invalidArguments(
                detail: "orderBy must be one of: "
                    + QueryStatisticsOrder.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        }
        return order
    }
}
