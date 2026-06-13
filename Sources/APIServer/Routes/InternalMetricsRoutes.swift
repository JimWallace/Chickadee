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
        // Served from a single-flight, short-TTL cache: the 30-day scan is
        // expensive, the dashboard polls it every 60s, and it must never stack
        // on the connection pool (see MetricsCardCache).  The compute closure
        // uses the application database, not `req.db`, since one caller's task
        // may be awaited by concurrent callers that outlive the original
        // request.
        let app = req.application
        return try await app.metricsCardCache.series {
            try await app.diagnostics.metricsCardSeries(on: app.db)
        }
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
