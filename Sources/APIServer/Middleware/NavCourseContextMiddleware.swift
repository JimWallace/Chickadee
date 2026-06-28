// APIServer/Middleware/NavCourseContextMiddleware.swift
//
// Resolves the course-aware nav context once per authenticated web request and
// caches it on the request, so the shared nav bar (the Instructor link and the
// course-tab strips, rendered by base.leaf) appears on *every* page.
//
// Without this, pages whose handlers build only a `req.currentUserContext` —
// the admin panel, the account page, the enrol page, and many others — render
// a course-free user context, so the Instructor link and course tabs vanish the
// moment you navigate to one of them. Populating the cache here lets
// `currentUserContext` return the course-aware snapshot uniformly, with no
// per-handler changes.
//
// Must sit downstream of the session authenticator so `auth.get(APIUser)` is
// populated. Best-effort: a resolution failure is swallowed so the nav simply
// degrades to the course-free fallback rather than failing the page.

import Vapor

struct NavCourseContextMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        if request.auth.has(APIUser.self) {
            _ = try? await request.courseAwareUserContext()
        }
        return try await next.respond(to: request)
    }
}
