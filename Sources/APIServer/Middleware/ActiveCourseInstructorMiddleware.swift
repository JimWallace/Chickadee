// APIServer/Middleware/ActiveCourseInstructorMiddleware.swift
//
// Gates the `/instructor` route group on *per-course* instructor authority
// (Phase 4b of docs/multi-course-roles.md). Replaces the global
// `RoleMiddleware(required: .instructor)` gate: instructor authority is now
// per-course, so the gate admits an admin (deployment-wide bypass) or a user
// who is an instructor in their *active course* — the course the instructor
// handlers act on (`resolveActiveCourse`). A user who is an instructor in one
// course but has a course where they're a student active is therefore kept out
// of the instructor tools for that student course.
//
// Must sit downstream of `UserSessionAuthenticator`. This gate covers the
// active-course-scoped handlers; handlers that act on a course or assignment
// named by a URL parameter additionally call `requireCourseRole(atLeast:)` on
// that target, so they can't be driven against another course by URL.

import Fluent
import Vapor

struct ActiveCourseInstructorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let user = request.auth.get(APIUser.self) else {
            if request.wantsBrowserRedirect { return request.redirect(to: "/login") }
            throw Abort(.unauthorized)
        }

        // Admins (deployment-wide) and — transitionally, until the global role
        // is shrunk in Phase 5 — global instructors are admitted to the section.
        // The param-taking actions inside still check per-course instructor
        // access on their target course, so this fallback widens "may open the
        // instructor section", not "may act on any course".
        if user.isInstructor {
            return try await next.respond(to: request)
        }

        // A per-course instructor who is not a global instructor reaches the
        // section only for the course they actually instruct (their active one).
        let state = try await request.resolveActiveCourse(for: user)
        if let activeCourseUUID = state.activeCourseUUID,
            let userID = user.id,
            let role = try await courseRole(of: userID, inCourse: activeCourseUUID, db: request.db),
            role >= .instructor
        {
            return try await next.respond(to: request)
        }

        // Authenticated but not an instructor here: 403, matching the prior
        // RoleMiddleware behaviour for an insufficient role.
        throw Abort(.forbidden)
    }
}

extension Request {
    /// True for a browser page request (not an `/api/` endpoint). Browser
    /// requests get a redirect rather than a bare status, mirroring
    /// `RoleMiddleware`'s own behaviour.
    fileprivate var wantsBrowserRedirect: Bool {
        !url.path.hasPrefix("/api/")
    }
}
