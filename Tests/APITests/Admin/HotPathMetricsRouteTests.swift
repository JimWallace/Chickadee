import Fluent
import Foundation
import NIOFoundationCompat
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

/// An idle runner poll does not persist a `request_metrics` row, but the
/// in-memory hot-path counts must still see it, and `/admin/metrics` must
/// report it.
@Suite(.serialized) final class HotPathMetricsRouteTests {
    private let workerSecret = "hot-path-secret"

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-hotpath")
        app.workerSecretStore = WorkerSecretStore(initialOverride: workerSecret)
        // `makeTestApp` does not install the production middleware chain, and
        // this middleware is what feeds the in-memory counts.
        app.middleware.use(RequestTimingMiddleware())
    }

    @Test func idleRunnerPollIsCountedInMemoryAndReported() async throws {
        try await withApp(app) { _ in
            let payload = WorkerActivityPayload(
                workerID: "runner-hot-path",
                hostname: "host-hot-path",
                runnerVersion: "runner/1.0.0",
                maxConcurrentJobs: 1,
                activeJobs: 0
            )
            let body = ByteBuffer(data: try JSONEncoder().encode(payload))
            let path = "/api/v1/worker/request"

            for _ in 0..<2 {
                try await app.asyncTest(
                    .POST, path,
                    beforeRequest: { req in
                        req.headers = workerHMACHeaders(
                            method: .POST,
                            path: path,
                            body: body,
                            workerSecret: self.workerSecret,
                            workerID: payload.workerID
                        )
                        req.body = body
                    },
                    afterResponse: { response in
                        #expect(response.status == .noContent)
                    })
            }

            let persisted = try await APIRequestMetric.query(on: app.db)
                .filter(\.$path == path)
                .count()
            #expect(persisted == 0)

            let cookie = try await loginUser(
                username: "admin-hot-path",
                password: "password123",
                role: "admin",
                on: app
            )
            try await app.asyncTest(
                .GET, "/admin/metrics",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { response in
                    #expect(response.status == .ok)
                    let metrics = try response.content.decode(InternalMetricsResponse.self)
                    let poll = try #require(
                        metrics.hotPaths.routes.first { $0.route == HotPathRoute.workerPoll.rawValue })
                    #expect(poll.sinceStart.requestCount == 2)
                    #expect(poll.sinceStart.errorCount == 0)
                    #expect(poll.lastWindow.requestCount == 2)
                    #expect(poll.sinceStart.p95Ms != nil)
                })
        }
    }
}
