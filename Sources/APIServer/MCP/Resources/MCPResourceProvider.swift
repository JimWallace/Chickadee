// APIServer/MCP/Resources/MCPResourceProvider.swift
//
// Backs the MCP `resources/list` and `resources/read` methods. Two resource
// kinds are exposed: an assignment's raw test-suite manifest
// (`test.properties.json`) — the canonical authoring spec (suites, pattern
// families, sections, required files) — and a small curated set of authoring
// guides from `docs/`. `get_suite` is the structured, filtered view of a
// manifest; the resource is the verbatim JSON, which is the MCP-idiomatic way
// to hand the model a document it can read into context. The guides exist so
// the server-level instructions can reference a recipe by URI instead of a
// repo path a connected agent cannot fetch.
//
// Course-scoped exactly like the tools: the listing is confined to courses the
// subject can act on (admins: all non-archived; everyone else: their
// enrolments), and a read re-checks `authorizeCourseAccess`. Nothing here
// touches student data, grades, or submissions — only authoring content.

import Core
import Fluent
import Foundation
import Vapor

struct MCPResourceProvider: Sendable {
    /// An authoring guide exposed read-only at `chickadee://docs/<slug>`.
    struct DocResource: Sendable {
        let slug: String
        /// Path relative to the application's working directory.
        let relativePath: String
        let name: String
        let description: String

        var uri: String { "chickadee://docs/\(slug)" }
    }

    /// The curated guides surfaced to agents. The server-level instructions
    /// reference these by URI; a guide whose file is missing on disk (e.g. a
    /// deployment that ships no docs tree) silently drops out of the listing
    /// and reads as an unknown resource.
    static let docResources: [DocResource] = [
        DocResource(
            slug: "personalization-solution-notebooks",
            relativePath: "docs/personalization-solution-notebooks.md",
            name: "Guide — per-student answers in notebooks and reference solutions",
            description: "How a per-student answer can be expressed in a notebook (the "
                + "extractor's import quarantine rule), and how the reference solution "
                + "produces the matching per-student value so validation passes. The "
                + "full recipe the server instructions reference.")
    ]

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
        // The guides are not course-scoped: a subject with no enrolments yet
        // still sees them.
        guard !courseByID.isEmpty else {
            return .object(["resources": .array(docEntries(context: context))])
        }

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
        return .object(["resources": .array(docEntries(context: context) + resources)])
    }

    // MARK: - Authoring-guide docs

    /// Listing entries for the curated guides whose files exist on disk.
    private func docEntries(context: ToolContext) -> [JSONValue] {
        Self.docResources.compactMap { doc in
            guard FileManager.default.fileExists(atPath: Self.docPath(doc, context: context)) else {
                return nil
            }
            return .object([
                "uri": .string(doc.uri),
                "name": .string(doc.name),
                "description": .string(doc.description),
                "mimeType": .string("text/markdown"),
            ])
        }
    }

    private static func docPath(_ doc: DocResource, context: ToolContext) -> String {
        context.request.application.directory.workingDirectory + doc.relativePath
    }

    /// Reads a curated guide, or throws the same "unknown resource" error the
    /// manifest path uses when the slug is unknown or the file is unreadable.
    private func readDoc(uri: String, context: ToolContext) async throws -> JSONValue {
        try await context.requireEligibleSubject(tool: "resources/read")
        guard let doc = Self.docResources.first(where: { $0.uri == uri }),
            let data = FileManager.default.contents(atPath: Self.docPath(doc, context: context)),
            let text = String(data: data, encoding: .utf8)
        else {
            throw MCPToolError.invalidArguments(
                tool: "resources/read", detail: "Unknown or inaccessible resource: \(uri)")
        }
        return .object([
            "contents": .array([
                .object([
                    "uri": .string(uri),
                    "mimeType": .string("text/markdown"),
                    "text": .string(text),
                ])
            ])
        ])
    }

    /// `resources/read`: returns the manifest JSON for the assignment named by
    /// `uri`. Course-scoped; an unknown URI and an inaccessible assignment are
    /// reported identically so a caller can't probe for assignments in courses
    /// it isn't enrolled in. Result shape: `{ "contents": [ { uri, mimeType,
    /// text } ] }`.
    func read(uri: String, context: ToolContext) async throws -> JSONValue {
        if uri.hasPrefix("chickadee://docs/") {
            return try await readDoc(uri: uri, context: context)
        }
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
