import Vapor

struct InternalMetricsRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let admin = routes.grouped("admin")
        admin.get("metrics", use: metrics)
        admin.get("metrics", "timeseries", use: timeseries)
        admin.get("metrics", "cards", use: cards)
    }

    @Sendable
    func metrics(req: Request) async throws -> InternalMetricsResponse {
        try await req.application.diagnostics.metricsSnapshot(req: req)
    }

    /// Sparkline series for the admin dashboard's diagnostic cards.  One
    /// payload carries every window (24h / 7d / 30d) so the client can cycle
    /// a card's window without another round-trip.
    @Sendable
    func cards(req: Request) async throws -> MetricsCardSeriesResponse {
        try await req.application.diagnostics.metricsCardSeries(on: req.db)
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
