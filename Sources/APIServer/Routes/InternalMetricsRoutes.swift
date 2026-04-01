import Vapor

struct InternalMetricsRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.grouped("admin")
            .get("metrics", use: metrics)
    }

    @Sendable
    func metrics(req: Request) async throws -> InternalMetricsResponse {
        try await req.application.diagnostics.metricsSnapshot(req: req)
    }
}
