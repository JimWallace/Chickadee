import Vapor

struct InternalMetricsRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let admin = routes.grouped("admin")
        admin.get("metrics", use: metrics)
        admin.get("metrics", "timeseries", use: timeseries)
    }

    @Sendable
    func metrics(req: Request) async throws -> InternalMetricsResponse {
        try await req.application.diagnostics.metricsSnapshot(req: req)
    }

    @Sendable
    func timeseries(req: Request) async throws -> InternalMetricsTimeSeriesResponse {
        struct Query: Content {
            var hours: Int?
            var bucketMinutes: Int?
        }

        let query = try req.query.decode(Query.self)
        return try await req.application.diagnostics.metricsTimeSeriesSnapshot(
            req: req,
            hours: query.hours,
            bucketMinutes: query.bucketMinutes
        )
    }
}
