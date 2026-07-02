// APIServer/Middleware/ActiveCourseStaffMiddleware.swift
//
// Gates the `/instructor` route group on *per-course* staff authority
// (Phase 4b of docs/multi-course-roles.md; renamed from
// ActiveCourseInstructorMiddleware in #1127 — it has admitted TAs since the
// Slice-E rung landed, so it is a staff gate). Replaces the global
// `RoleMiddleware(required: .instructor)` gate: teaching authority is
// per-course, so the gate admits an admin (deployment-wide bypass) or a user
// who is staff (TA+) in their *active course* — the course the instructor
// handlers act on (`resolveActiveCourse`). A user who is staff in one course
// but has a course where they're a student active is therefore kept out of
// the instructor tools for that student course.
//
// Must sit downstream of `UserSessionAuthenticator`. This gate covers the
// active-course-scoped handlers; handlers that act on a course or assignment
// named by a URL parameter additionally call `requireCourseRole(atLeast:)` on
// that target, so they can't be driven against another course by URL.

import Fluent
import Vapor

struct ActiveCourseStaffMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let user = request.auth.get(APIUser.self) else {
            if request.wantsBrowserRedirect { return request.redirect(to: "/login") }
            throw Abort(.unauthorized)
        }

        // Admins administer the whole deployment.
        if user.isAdmin {
            return try await next.respond(to: request)
        }

        // Everyone else must be staff (TA or instructor) in their active course
        // to enter the instructor area. Authority is per-course — the global
        // instructor role no longer grants it (multi-course-roles Phase 5). This
        // gate only opens the *area*; each mutating handler enforces its own
        // finer floor (content edits/grading at `.ta`, enrollment/deadline/
        // archive/delete at `.instructor`) via requireCourseWriteAccess (#417
        // Slice E).
        let state = try await request.resolveActiveCourse(for: user)
        if let activeCourseUUID = state.activeCourseUUID,
            let userID = user.id,
            let role = try await courseRole(of: userID, inCourse: activeCourseUUID, db: request.db),
            role >= .ta
        {
            return try await next.respond(to: request)
        }

        // Authenticated but not staff here: 403, matching the prior
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
