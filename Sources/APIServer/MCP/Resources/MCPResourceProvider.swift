// APIServer/MCP/Resources/MCPResourceProvider.swift
//
// Backs the MCP `resources/list` and `resources/read` methods. The one resource
// kind exposed is an assignment's raw test-suite manifest (`test.properties.json`)
// — the canonical authoring spec (suites, pattern families, sections, required
// files). `get_suite` is the structured, filtered view; the resource is the
// verbatim JSON, which is the MCP-idiomatic way to hand the model a document it
// can read into context.
//
// Course-scoped exactly like the tools: the listing is confined to courses the
// subject can act on (admins: all non-archived; everyone else: their
// enrolments), and a read re-checks `authorizeCourseAccess`. Nothing here
// touches student data, grades, or submissions — only authoring content.

import Core
import Fluent
import Vapor

struct MCPResourceProvider: Sendable {
    /// `chickadee://assignment/<publicID>/manifest`
    static func manifestURI(publicID: String) -> String {
        "chickadee://assignment/\(publicID)/manifest"
    }

    /// Parses an assignment public ID out of a manifest resource URI, or nil if
    /// `uri` is not a well-formed manifest URI.
    static func manifestPublicID(fromURI uri: String) -> String? {
        let prefix = "chickadee://assignment/"
        let suffix = "/manifest"
        guard uri.hasPrefix(prefix), uri.hasSuffix(suffix) else { return nil }
        let inner = String(uri.dropFirst(prefix.count).dropLast(suffix.count))
        guard !inner.isEmpty, !inner.contains("/") else { return nil }
        return inner
    }

    /// `resources/list`: one manifest resource per assignment the subject may
    /// act on. Result shape: `{ "resources": [ { uri, name, description,
    /// mimeType } ] }`.
    func list(context: ToolContext) async throws -> JSONValue {
        let user = try await context.requireEligibleSubject(tool: "resources/list")

        let courses: [APICourse]
        if user.isAdmin {
            courses = try await APICourse.query(on: context.db)
                .filter(\.$isArchived == false)
                .all()
        } else if let userID = user.id {
            let enrollments = try await APICourseEnrollment.query(on: context.db)
                .filter(\.$userID == userID)
                .all()
            let courseIDs = Array(Set(enrollments.map { $0.$course.id }))
            courses =
                courseIDs.isEmpty
                ? []
                : try await APICourse.query(on: context.db).filter(\.$id ~~ courseIDs).all()
        } else {
            courses = []
        }

        let courseByID = Dictionary(
            courses.compactMap { course in course.id.map { ($0, course) } },
            uniquingKeysWith: { first, _ in first })
        guard !courseByID.isEmpty else { return .object(["resources": .array([])]) }

        let assignments = try await APIAssignment.query(on: context.db)
            .filter(\.$courseID ~~ Array(courseByID.keys))
            .sort(\.$title)
            .all()

        let resources: [JSONValue] = assignments.compactMap { assignment in
            guard let course = courseByID[assignment.courseID] else { return nil }
            return .object([
                "uri": .string(Self.manifestURI(publicID: assignment.publicID)),
                "name": .string("\(course.code) — \(assignment.title) (test suite manifest)"),
                "description": .string(
                    "Raw test.properties.json for assignment \(assignment.publicID) in "
                        + "\(course.code): test suites, pattern families, sections, and required "
                        + "files. The canonical authoring spec; get_suite is the structured view."),
                "mimeType": .string("application/json"),
            ])
        }
        return .object(["resources": .array(resources)])
    }

    /// `resources/read`: returns the manifest JSON for the assignment named by
    /// `uri`. Course-scoped; an unknown URI and an inaccessible assignment are
    /// reported identically so a caller can't probe for assignments in courses
    /// it isn't enrolled in. Result shape: `{ "contents": [ { uri, mimeType,
    /// text } ] }`.
    func read(uri: String, context: ToolContext) async throws -> JSONValue {
        guard let publicID = Self.manifestPublicID(fromURI: uri),
            let assignment = try await assignmentByPublicID(publicID, on: context.db)
        else {
            throw MCPToolError.invalidArguments(
                tool: "resources/read", detail: "Unknown or inaccessible resource: \(uri)")
        }
        do {
            try await context.authorizeCourseAccess(assignment.courseID, tool: "resources/read")
        } catch {
            // Collapse a course-authorization failure into the same "unknown
            // resource" response so the URI space can't be enumerated.
            throw MCPToolError.invalidArguments(
                tool: "resources/read", detail: "Unknown or inaccessible resource: \(uri)")
        }
        guard let setup = try await APITestSetup.find(assignment.testSetupID, on: context.db) else {
            throw MCPToolError.executionFailed(
                tool: "resources/read", detail: "The assignment's test setup could not be found.")
        }
        return .object([
            "contents": .array([
                .object([
                    "uri": .string(uri),
                    "mimeType": .string("application/json"),
                    "text": .string(setup.manifest),
                ])
            ])
        ])
    }
}
