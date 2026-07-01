// APIServer/Routes/Web/VanityURLRoutes.swift
//
// Vanity URL support: GET /:courseCode/:assignmentSlug
//
// Resolves a human-readable course/assignment pair to canonical student
// assignment routes. Slugs are persisted on assignments so URLs remain stable
// when titles change. Only active (non-archived) courses match.
//
// Registered last in the auth group so fixed-path routes always win.

import Fluent
import Vapor

struct VanityURLRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":courseCode", ":assignmentSlug", use: vanityRedirect)
        routes.get(":courseCode", ":assignmentSlug", "notebook", use: vanityNotebookRedirect)
        routes.get(":courseCode", ":assignmentSlug", "submit", use: vanitySubmitRedirect)
        routes.get(":courseCode", ":assignmentSlug", "history", use: vanityHistoryRedirect)
    }

    @Sendable
    func vanityRedirect(req: Request) async throws -> Response {
        let assignment = try await resolveAssignment(req: req)
        return req.redirect(to: "/testsetups/\(assignment.testSetupID)/notebook")
    }

    @Sendable
    func vanityNotebookRedirect(req: Request) async throws -> Response {
        let assignment = try await resolveAssignment(req: req)
        return req.redirect(to: "/testsetups/\(assignment.testSetupID)/notebook")
    }

    @Sendable
    func vanitySubmitRedirect(req: Request) async throws -> Response {
        let assignment = try await resolveAssignment(req: req)
        return req.redirect(to: "/testsetups/\(assignment.testSetupID)/submit")
    }

    @Sendable
    func vanityHistoryRedirect(req: Request) async throws -> Response {
        let assignment = try await resolveAssignment(req: req)
        return req.redirect(to: "/testsetups/\(assignment.testSetupID)/history")
    }

    private func resolveAssignment(req: Request) async throws -> APIAssignment {
        let user = try req.auth.require(APIUser.self)
        guard
            let courseCode = req.parameters.get("courseCode"),
            let slug = req.parameters.get("assignmentSlug")
        else {
            throw Abort(.notFound)
        }

        guard let course = try await findActiveCourse(byCode: courseCode, on: req.db) else {
            throw Abort(.notFound)
        }

        let courseID = try course.requireID()

        // Treat unenrolled access as 404 (matching the no-such-course /
        // no-such-assignment cases) so vanity URLs aren't a course /
        // assignment enumeration vector for students browsing the
        // institutional catalogue.  Staff (TA+ or admin) of this course bypass
        // (#417 Slice G — was the global `isInstructor` short-circuit); a plain
        // enrolled student still passes the enrollment check below.
        if !(try await isCourseStaff(user, inCourse: courseID, db: req.db)) {
            let userID = try user.requireID()
            let enrolled =
                try await APICourseEnrollment.query(on: req.db)
                .filter(\.$userID == userID)
                .filter(\.$course.$id == courseID)
                .count() > 0
            guard enrolled else {
                throw Abort(.notFound)
            }
        }

        guard
            let assignment = try await APIAssignment.query(on: req.db)
                .filter(\.$courseID == courseID)
                .filter(\.$slug == slug)
                .first()
        else {
            throw Abort(.notFound)
        }

        return assignment
    }

    static func vanityPath(courseCode: String, assignmentSlug: String) -> String {
        "/\(courseCode)/\(assignmentSlug)"
    }

    static func slugify(_ title: String) -> String {
        let parts = title.lowercased().split { !$0.isASCII || (!$0.isLetter && !$0.isNumber) }
        return parts.joined(separator: "-")
    }
}
