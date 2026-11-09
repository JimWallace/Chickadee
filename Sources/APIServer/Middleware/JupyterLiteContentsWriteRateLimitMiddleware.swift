// APIServer/Middleware/JupyterLiteContentsWriteRateLimitMiddleware.swift
//
// Per-user sliding-window rate limit on the editor's contents write routes
// (#2926, JupyterLiteContentsRoutes+Write.swift). Reuses the
// login_attempts-backed `LoginAttemptService` under its own scope
// (`contents_write`, keyed by user id), so the count is shared across server
// processes (#1154).
//
// Keyed by user, not IP: a lab's students share one address behind NAT, and
// the routes require a signed-in user. A request with no user passes through
// to the handler, which refuses it.

import Fluent
import Foundation
import Vapor

struct JupyterLiteContentsWriteRateLimitMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let userID = request.auth.get(APIUser.self)?.id else {
            return try await next.respond(to: request)
        }
        let limit = request.application.jupyterLiteContentsWriteLimits.writesPerMinute
        let allowed = try await LoginAttemptService.recordAndCheck(
            scope: LoginAttempt.Scope.contentsWrite,
            key: userID.uuidString.lowercased(),
            now: Date(),
            windowSeconds: 60,
            max: limit,
            on: request.db
        )
        guard allowed else {
            request.logger.warning(
                "jupyterlite_contents_write_rate_limited",
                metadata: [
                    "user_id": .string(userID.uuidString.lowercased()),
                    "method": .string(request.method.rawValue),
                    "limit_per_minute": .stringConvertible(limit),
                ])
            let response = Response(status: .tooManyRequests)
            response.headers.replaceOrAdd(name: "Retry-After", value: "60")
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            try response.content.encode(["error": "rate_limited"])
            return response
        }
        return try await next.respond(to: request)
    }
}
