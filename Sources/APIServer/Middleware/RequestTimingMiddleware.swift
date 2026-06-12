import Foundation
import Vapor

struct RequestTimingMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let startDate = Date()
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let response = try await next.respond(to: request)
            await request.application.diagnostics.recordRequestMetric(
                buildMetric(
                    request: request,
                    statusCode: Int(response.status.code),
                    startedAt: startDate,
                    durationMs: milliseconds(from: start.duration(to: clock.now))
                ),
                on: request.db,
                logger: request.logger
            )
            return response
        } catch {
            let statusCode = (error as? AbortError)?.status.code ?? HTTPResponseStatus.internalServerError.code
            await request.application.diagnostics.recordRequestMetric(
                buildMetric(
                    request: request,
                    statusCode: Int(statusCode),
                    startedAt: startDate,
                    durationMs: milliseconds(from: start.duration(to: clock.now))
                ),
                on: request.db,
                logger: request.logger
            )
            throw error
        }
    }

    private func buildMetric(
        request: Request,
        statusCode: Int,
        startedAt: Date,
        durationMs: Int
    ) -> APIRequestMetric {
        APIRequestMetric(
            method: request.method.rawValue,
            path: request.url.path,
            requestKind: requestKind(for: request.url.path),
            statusCode: statusCode,
            startedAt: startedAt,
            finishedAt: Date(),
            durationMs: durationMs,
            submissionID: request.parameters.get("submissionID"),
            workerID: request.headers.first(name: "X-Worker-Id")
        )
    }
}

private func requestKind(for path: String) -> String {
    if path == "/api/v1/worker/request" { return "job_dispatch" }
    if path == "/api/v1/worker/results" { return "result_writeback" }
    if path.hasPrefix("/api/") { return "api" }
    return "web"
}

private func milliseconds(from duration: Duration) -> Int {
    let components = duration.components
    let seconds = components.seconds * 1_000
    let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
    let millisecondsFromAttoseconds = components.attoseconds / attosecondsPerMillisecond
    return Int(seconds + millisecondsFromAttoseconds)
}
