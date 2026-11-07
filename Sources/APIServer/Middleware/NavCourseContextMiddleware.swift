// APIServer/Middleware/NavCourseContextMiddleware.swift
//
// Resolves the course-aware nav context once per authenticated web request and
// caches it on the request, so the shared nav bar (the Instructor link and the
// course-tab strips, rendered by BaseLayout) appears on *every* page.
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
//
// A JSON API request (`/api/…`) renders no nav, so it skips the resolution:
// no `/api/` handler reads the cached context, and `ErrorPageMiddleware`
// answers `/api/` errors as JSON. The resolution costs three queries, and the
// busiest request of a deadline, the result view's 2 s status poll
// (`GET /api/v1/submissions/:id`), is one of these. A handler that needs the
// active course still resolves it on demand through `resolveActiveCourse`.
//
// The resolution also has side effects, which an `/api/` request therefore
// leaves to the user's next page view: auto-enrolment in every `.auto`
// course, the session's `activeCourseID`, and drawing a missing bird. A
// browser reaches an `/api/` door only from a page it has loaded, and
// sign-in redirects to a page, so those have already run for the session.

import Vapor

struct NavCourseContextMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if request.auth.has(APIUser.self), !Self.isJSONAPIPath(request.url.path) {
            _ = try? await request.courseAwareUserContext()
        }
        return try await next.respond(to: request)
    }

    /// True for a JSON API path, which renders no nav bar.
    static func isJSONAPIPath(_ path: String) -> Bool {
        path.hasPrefix("/api/")
    }
}
