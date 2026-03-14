// APIServer/Routes/HealthRoutes.swift
//
// Public health check endpoint used by nginx, load balancers, and monitoring tools.
//
//   GET /health  → 200 OK (all systems operational)
//              → 503 Service Unavailable (DB unreachable)

import Vapor
import Fluent
import SQLKit
import Core

struct HealthRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("health", use: health)
    }

    @Sendable
    func health(req: Request) async throws -> Response {
        // DB check: run a trivial query and catch errors.
        let dbStatus: String
        do {
            guard let sql = req.db as? SQLDatabase else {
                dbStatus = "error"
                throw Abort(.internalServerError)
            }
            _ = try await sql.raw("SELECT 1").all()
            dbStatus = "ok"
        } catch {
            let payload = HealthResponse(
                status: "degraded",
                version: ChickadeeVersion.current,
                db: "error",
                runner: .init(recentActivity: false)
            )
            var headers = HTTPHeaders()
            headers.contentType = .json
            let body = try JSONEncoder().encode(payload)
            return Response(status: .serviceUnavailable, headers: headers, body: .init(data: body))
        }

        let hasRunnerActivity = await req.application.workerActivityStore.hasRecentActivity(within: 120)

        let payload = HealthResponse(
            status: "ok",
            version: ChickadeeVersion.current,
            db: dbStatus,
            runner: .init(recentActivity: hasRunnerActivity)
        )
        return try await payload.encodeResponse(status: .ok, for: req)
    }
}

// MARK: - Response types

private struct HealthResponse: Content {
    var status: String   // "ok" | "degraded"
    var version: String
    var db: String       // "ok" | "error"
    var runner: RunnerHealth

    struct RunnerHealth: Content {
        var recentActivity: Bool
    }
}
