// Tests/APITests/RequestTimingMiddlewareTests.swift
//
// RequestTimingMiddleware feeds the request_metrics table behind the admin
// dashboard and the get_request_metrics diagnostic tool. Shipped in v0.4.573
// but only registered in the chain as of the 2026-07 audit pass — these tests
// pin (a) that captured routes actually produce rows now, and (b) that idle
// runner check-ins are excluded so hot-path worker polls don't become
// per-poll INSERTs.

import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class RequestTimingMiddlewareTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-reqtiming")
        // makeTestApp builds a minimal middleware chain (it doesn't run
        // bootstrapAppMiddleware), so attach the middleware under test the
        // way the production chain does.
        app.middleware.use(RequestTimingMiddleware())
    }

    private func metricCount(path: String) async throws -> Int {
        try await APIRequestMetric.query(on: app.db)
            .filter(\.$path == path)
            .count()
    }

    private func recordMetric(method: String = "POST", path: String, statusCode: Int) async {
        await app.diagnostics.recordRequestMetric(
            APIRequestMetric(
                method: method,
                path: path,
                requestKind: "job_dispatch",
                statusCode: statusCode,
                startedAt: Date(),
                finishedAt: Date(),
                durationMs: 5,
                submissionID: nil,
                workerID: "w1"
            ),
            on: app.db,
            logger: app.logger
        )
    }

    /// End-to-end through the responder chain: an /api/* request leaves a
    /// request_metrics row (this exact pipeline was silently empty while the
    /// middleware was unregistered in the production chain).
    @Test func capturedAPIRequestPersistsMetricRow() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "timing_admin", password: "testpassword", role: "admin", on: app)
            try await app.asyncTest(
                .GET, "/api/v1/submissions",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.status == .ok) })

            let apiRows = try await metricCount(path: "/api/v1/submissions")
            #expect(apiRows >= 1)
        }
    }

    /// An idle worker poll (204, no job) must NOT persist a metric row —
    /// that would be one INSERT per runner per second.
    @Test func idleWorkerPollIsNotPersisted() async throws {
        try await withApp(app) { _ in
            await recordMetric(path: "/api/v1/worker/request", statusCode: 204)
            let idlePollRows = try await metricCount(path: "/api/v1/worker/request")
            #expect(idlePollRows == 0)
        }
    }

    /// A real job dispatch (200) and a failing check-in (>=400) still record.
    @Test func realDispatchAndErrorsArePersisted() async throws {
        try await withApp(app) { _ in
            await recordMetric(path: "/api/v1/worker/request", statusCode: 200)
            let dispatchRows = try await metricCount(path: "/api/v1/worker/request")
            #expect(dispatchRows == 1)

            await recordMetric(path: "/api/v1/worker/heartbeat", statusCode: 200)
            let healthyHeartbeatRows = try await metricCount(path: "/api/v1/worker/heartbeat")
            #expect(healthyHeartbeatRows == 0)

            await recordMetric(path: "/api/v1/worker/heartbeat", statusCode: 500)
            let failedHeartbeatRows = try await metricCount(path: "/api/v1/worker/heartbeat")
            #expect(failedHeartbeatRows == 1)
        }
    }

    /// The student result view polls the bare submission-status route every two
    /// seconds while a submission is pending, so during a deadline it is the
    /// highest-frequency request the server takes. Recording each one turns a
    /// read into a write exactly when the database is busiest — the idle-runner
    /// exclusion above, arriving from the client side.
    @Test func submissionStatusPollIsNotPersisted() async throws {
        try await withApp(app) { _ in
            await recordMetric(method: "GET", path: "/api/v1/submissions/sub_abc123", statusCode: 200)
            let pollRows = try await metricCount(path: "/api/v1/submissions/sub_abc123")
            #expect(pollRows == 0)
        }
    }

    /// A poll that starts failing has to stay visible — the exclusion is for
    /// volume, not for hiding a broken route.
    @Test func failingSubmissionStatusPollIsPersisted() async throws {
        try await withApp(app) { _ in
            await recordMetric(method: "GET", path: "/api/v1/submissions/sub_err", statusCode: 500)
            let errorRows = try await metricCount(path: "/api/v1/submissions/sub_err")
            #expect(errorRows == 1)
        }
    }

    /// The exclusion is scoped to the bare status route. Its sub-routes are
    /// real work — `/results` reads and decodes the outcome blob — and a
    /// non-GET against the same path is not a poll at all.
    @Test func submissionSubroutesAndWritesStillPersist() async throws {
        try await withApp(app) { _ in
            await recordMetric(
                method: "GET", path: "/api/v1/submissions/sub_abc123/results", statusCode: 200)
            let resultRows = try await metricCount(path: "/api/v1/submissions/sub_abc123/results")
            #expect(resultRows == 1)

            await recordMetric(
                method: "GET", path: "/api/v1/submissions/sub_abc123/download", statusCode: 200)
            let downloadRows = try await metricCount(path: "/api/v1/submissions/sub_abc123/download")
            #expect(downloadRows == 1)

            await recordMetric(method: "DELETE", path: "/api/v1/submissions/sub_abc123", statusCode: 200)
            let deleteRows = try await metricCount(path: "/api/v1/submissions/sub_abc123")
            #expect(deleteRows == 1)
        }
    }
}
