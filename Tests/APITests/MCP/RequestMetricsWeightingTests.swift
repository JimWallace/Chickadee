// Tests/APITests/MCP/RequestMetricsWeightingTests.swift
//
// get_request_metrics keeps each route's durations as (duration, count)
// pairs. Its summary must equal `durationSummary` over the expanded list,
// and the path prefix and the window must filter as they did when the tool
// read single rows.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class RequestMetricsWeightingTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "request-metrics-weighting")
    }

    private func context(subject: String) -> AdminToolContext {
        AdminToolContext(request: makeTestRequest(on: app), subject: subject, grantedScopes: [.read])
    }

    @Test(arguments: [
        [(10, 1)],
        [(10, 19), (900, 1)],
        [(900, 19), (10, 1)],
        [(5, 3), (7, 2), (40, 6), (41, 1), (300, 4)],
        [(1, 1), (2, 1), (3, 1), (4, 1), (5, 1), (6, 1), (7, 1)],
    ])
    func weightedSummaryMatchesTheExpandedSummary(pairs: [(Int, Int)]) async throws {
        try await withApp(app) { app in
            var weighted = GetRequestMetricsTool.WeightedDurations()
            var expanded: [Int] = []
            for (durationMs, count) in pairs {
                weighted.add(durationMs, count: count)
                expanded += Array(repeating: durationMs, count: count)
            }
            let expected = app.diagnostics.durationSummary(for: expanded)
            let actual = weighted.summary()
            #expect(actual.averageMs == expected.averageMs)
            #expect(actual.p50Ms == expected.p50Ms)
            #expect(actual.p95Ms == expected.p95Ms)
            #expect(weighted.total == expanded.count)
            #expect(weighted.max == expanded.max())
        }
    }

    @Test func emptyWeightedSummaryHasNoValues() async throws {
        try await withApp(app) { _ in
            let summary = GetRequestMetricsTool.WeightedDurations().summary()
            #expect(summary.averageMs == nil)
            #expect(summary.p50Ms == nil)
            #expect(summary.p95Ms == nil)
        }
    }

    @Test func prefixAndWindowFilterTheGroups() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "rmw-admin", role: "admin")
            let now = Date()
            let old = now.addingTimeInterval(-48 * 3600)
            for (path, finishedAt) in [
                ("/api/v1/submissions/sub_aaaaaaaa", now),
                ("/api/v1/submissions/sub_bbbbbbbb", now),
                ("/testsetups/setup_cccccccc/download", now),
                ("/api/v1/submissions/sub_dddddddd", old),
            ] {
                try await APIRequestMetric(
                    method: "GET", path: path, requestKind: nil, statusCode: 200, startedAt: finishedAt,
                    finishedAt: finishedAt, durationMs: 20, submissionID: nil, workerID: nil
                ).save(on: app.db)
            }

            let day = try await GetRequestMetricsTool().execute(.init(), context(subject: "rmw-admin"))
            #expect(day.total == 3)

            let twoDays = try await GetRequestMetricsTool().execute(
                .init(windowHours: 72), context(subject: "rmw-admin"))
            #expect(twoDays.total == 4)

            // A concrete id in the prefix collapses to ":id", so it matches
            // every submission route, not the one id.
            let prefixed = try await GetRequestMetricsTool().execute(
                .init(pathPrefix: "/api/v1/submissions/sub_aaaaaaaa"), context(subject: "rmw-admin"))
            #expect(prefixed.total == 2)
            #expect(prefixed.slowestRoutes.map(\.route) == ["GET /api/v1/submissions/:id"])
        }
    }
}
