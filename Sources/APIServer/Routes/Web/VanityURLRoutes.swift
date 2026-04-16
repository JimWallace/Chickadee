// APIServer/Routes/Web/VanityURLRoutes.swift
//
// Vanity URL support: GET /:courseCode/:assignmentSlug
//
// Resolves a human-readable course/assignment pair to the canonical notebook
// URL for that assignment. Slug is derived from the assignment title by
// lowercasing and stripping non-alphanumeric characters (e.g. "Lab 1: Intro"
// → "lab1intro"). Only active (non-archived) courses match.
//
// Registered last in the auth group so fixed-path routes always win.

import Vapor
import Fluent

struct VanityURLRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":courseCode", ":assignmentSlug", use: vanityRedirect)
    }

    @Sendable
    func vanityRedirect(req: Request) async throws -> Response {
        guard
            let courseCode = req.parameters.get("courseCode"),
            let slug = req.parameters.get("assignmentSlug")
        else {
            throw Abort(.notFound)
        }

        let courseCodeLower = courseCode.lowercased()
        let activeCourses = try await APICourse.query(on: req.db)
            .filter(\.$isArchived == false)
            .all()
        guard let course = activeCourses.first(where: { $0.code.lowercased() == courseCodeLower }) else {
            throw Abort(.notFound)
        }

        let courseID = try course.requireID()
        let assignments = try await APIAssignment.query(on: req.db)
            .filter(\.$courseID == courseID)
            .all()

        guard let assignment = assignments.first(where: { VanityURLRoutes.slugify($0.title) == slug }) else {
            throw Abort(.notFound)
        }

        return req.redirect(to: "/testsetups/\(assignment.testSetupID)/notebook")
    }

    static func slugify(_ title: String) -> String {
        title.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
