// APIServer/Routes/UWDatesRoute.swift
//
// GET /api/v1/uw-dates
// Returns upcoming UWaterloo important dates as JSON for client-side due-date warnings.
// Registered under the instructor middleware group (only instructors set due dates).

import Vapor

struct UWDatesRoute: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("api", "v1", "uw-dates", use: handle)
    }

    @Sendable
    func handle(req: Request) async throws -> Response {
        let dates = await req.application.uwImportantDatesCache.fetchDates(
            client: req.client,
            logger: req.logger
        )
        let body = try JSONEncoder().encode(dates)
        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: body)
        )
    }
}
