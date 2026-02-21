// APIServer/Middleware/RoleMiddleware.swift
//
// Guards a route group so only users with sufficient role can proceed.
// Must be placed downstream of UserSessionAuthenticator in the middleware stack.
//
// Unauthenticated browser requests are redirected to /login.
// Unauthenticated API requests (Accept: application/json) receive 401.
// Authenticated users with insufficient role always receive 403.

import Vapor

struct RoleMiddleware: AsyncMiddleware {

    enum Required {
        case authenticated      // any logged-in user
        case instructor         // instructor or admin
        case admin              // admin only
    }

    let required: Required

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let user = request.auth.get(APIUser.self) else {
            // Not authenticated.
            if request.prefersBrowser {
                return request.redirect(to: "/login")
            }
            throw Abort(.unauthorized)
        }

        switch required {
        case .authenticated:
            break
        case .instructor:
            guard user.isInstructor else { throw Abort(.forbidden) }
        case .admin:
            guard user.isAdmin else { throw Abort(.forbidden) }
        }

        return try await next.respond(to: request)
    }
}

// MARK: - Helper

private extension Request {
    /// True when the request is for a browser page (not a /api/v1/ endpoint).
    /// We use the URL path rather than Accept header so that XCTVapor tests
    /// (which send no Accept header) still get redirects on browser routes.
    var prefersBrowser: Bool {
        !url.path.hasPrefix("/api/")
    }
}
