// APIServer/Routes/Web/VanityURLRoutes.swift
//
// Vanity URL support: GET /:courseCode/:assignmentSlug
//
// The first segment is a course URL key: the code, or the code and term
// ("CS135-F26") when the course records a term (docs/course-terms.md).
//
// Resolves a human-readable course/assignment pair to canonical student
// assignment routes. Slugs are persisted on assignments so URLs remain stable
// when titles change. Only active (non-archived) courses match.
//
// The router tries a constant segment before a parameter at every step and
// never backtracks, so any fixed route wins over these whatever the
// registration order. A course whose code is the first segment of a fixed route
// would lose its links; `ReservedCourseKeys` refuses such codes and the
// `courseKeyShadowed` health rule reports any that remain (#2666).

import Fluent
import Vapor

struct VanityURLRoutes: RouteCollection {
    /// Each vanity suffix and the canonical student page it redirects to. The
    /// bare pair opens the notebook.
    static let suffixes: [(suffix: String?, page: String)] = [
        (nil, "notebook"),
        ("notebook", "notebook"),
        ("submit", "submit"),
        ("history", "history"),
        ("leaderboard", "leaderboard"),
    ]

    func boot(routes: any RoutesBuilder) throws {
        for (suffix, page) in Self.suffixes {
            var path: [PathComponent] = [":courseCode", ":assignmentSlug"]
            if let suffix { path.append(.constant(suffix)) }
            routes.get(path) { req async throws -> Response in
                let assignment = try await resolveAssignment(req: req)
                return req.redirect(to: "/testsetups/\(assignment.testSetupID)/\(page)")
            }
        }
    }

    private func resolveAssignment(req: Request) async throws -> APIAssignment {
        let user = try req.auth.require(APIUser.self)
        guard
            let courseCode = req.parameters.get("courseCode"),
            let slug = req.parameters.get("assignmentSlug")
        else {
            throw AppError.notFound(resource: "Assignment")
        }

        guard let course = try await findActiveCourse(byKey: courseCode, viewer: user.id, on: req.db) else {
            throw AppError.notFound(resource: "Assignment")
        }

        let courseID = try course.requireID()

        // Treat unenrolled access as 404 (matching the no-such-course /
        // no-such-assignment cases) so vanity URLs aren't a course /
        // assignment enumeration vector for students browsing the
        // institutional catalogue.  Staff (TA+ or admin) of this course bypass
        // (#417 Slice G — was the global `isInstructor` short-circuit); a plain
        // enrolled student still passes the enrollment check below. Both
        // checks read the request's role memo, so the enrollment row is read
        // once (a role is nil exactly when there is no enrollment row).
        if !(try await req.cachedIsCourseStaff(user, inCourse: courseID)) {
            guard try await req.cachedCourseRole(of: try user.requireID(), inCourse: courseID) != nil else {
                throw AppError.notFound(resource: "Assignment")
            }
        }

        guard
            let assignment = try await APIAssignment.query(on: req.db)
                .filter(\.$courseID == courseID)
                .filter(\.$slug == slug)
                .first()
        else {
            throw AppError.notFound(resource: "Assignment")
        }

        // The redirect names the setup ID, which the content routes take. A
        // student is not told an assignment exists before it opens, nor given
        // a preview's or a draft's ID (#2897); 404 as for the cases above.
        guard
            try await studentMayReadAssignmentContent(
                testSetupID: assignment.testSetupID, courseID: courseID, user: user, on: req)
        else {
            throw AppError.notFound(resource: "Assignment")
        }

        return assignment
    }

    /// Pass the course's `urlKey` ("CS135" or "CS135-F26") as `courseCode`,
    /// not its bare code, so the link names one offering. Each segment is
    /// percent-encoded, so a key with a space gives a valid `Location` header.
    static func vanityPath(courseCode: String, assignmentSlug: String) -> String {
        "/\(urlEncode(courseCode))/\(urlEncode(assignmentSlug))"
    }
}
