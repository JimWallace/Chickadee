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
// Course-scoped exactly like the tools: the listing is confined to the
// subject's non-archived enrolments (admins included — the shared
// `enrolledCourses` resolver carries no role bypass), and a read re-checks
// `authorizeCourseAccess`. Nothing here touches student data, grades, or
// submissions — only authoring content.

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

    /// An authoring guide served from an in-binary constant rather than a file
    /// on disk, exposed read-only at the same `chickadee://docs/<slug>`
    /// namespace. Keeps the source of truth in code — the authoring-voice
    /// guide below is the very constant the `initialize` instructions embed —
    /// so the resource can never drift from what initialize serves.
    struct InlineDocResource: Sendable {
        let slug: String
        let name: String
        let description: String
        let text: String

        var uri: String { "chickadee://docs/\(slug)" }
    }

    /// Constant-backed guides, always present regardless of the docs tree.
    static let inlineDocResources: [InlineDocResource] = [
        InlineDocResource(
            slug: "authoring-voice",
            name: "Guide — authoring voice for Chickadee assignments",
            description: "Chickadee's default authoring-voice guide, identical to the block "
                + "the initialize instructions end with: the register instructional prose is "
                + "written in, the required and prohibited patterns, and a worked example. "
                + "Every course starts on this guide; a course whose instructors have "
                + "replaced it serves its own at chickadee://course/<code>/authoring-guidance.",
            text: MCPServerInstructions.authoringVoice)
    ]

    /// `chickadee://course/<code>/authoring-guidance` — the per-course guidance
    /// a course's instructors set on the instructor MCP panel. Unlike the
    /// initialize embedding (frozen per connection), the resource re-reads the
    /// live value, so an agent can pick up edits mid-session.
    static func courseGuidanceURI(courseCode: String) -> String {
        "chickadee://course/\(courseCode)/authoring-guidance"
    }

    /// Parses a course code out of a guidance resource URI, or nil if `uri` is
    /// not a well-formed guidance URI.
    static func courseGuidanceCode(fromURI uri: String) -> String? {
        let prefix = "chickadee://course/"
        let suffix = "/authoring-guidance"
        guard uri.hasPrefix(prefix), uri.hasSuffix(suffix) else { return nil }
        let inner = String(uri.dropFirst(prefix.count).dropLast(suffix.count))
        guard !inner.isEmpty, !inner.contains("/") else { return nil }
        return inner
    }

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

        // The shared visibility resolver: non-archived enrolled courses, for
        // every role — an admin's agent sees its enrolments, not the world.
        let courses: [APICourse]
        if let userID = user.id {
            courses = try await enrolledCourses(for: userID, on: context.db)
        } else {
            courses = []
        }

        let courseByID = Dictionary(
            courses.compactMap { course in course.id.map { ($0, course) } },
            uniquingKeysWith: { first, _ in first })
        // Per-course authoring guidance, for the courses the subject can
        // author in (same resolver the initialize embedding uses, so the two
        // surfaces can't disagree about who sees which course's guidance).
        let guidanceEntries: [JSONValue] = try await mcpCourseGuidance(
            forSubject: context.subject, db: context.db
        ).map { guidance in
            let origin =
                guidance.isCustomized
                ? "The course's own guide, set by its instructors"
                : "Chickadee's default guide, which this course has not customized"
            return .object([
                "uri": .string(Self.courseGuidanceURI(courseCode: guidance.courseCode)),
                "name": .string("\(guidance.courseCode) — authoring voice"),
                "description": .string(
                    "The authoring voice in force for \(guidance.courseCode): the register, "
                        + "vocabulary, and conventions to write its instructional prose in. "
                        + "\(origin). Read this before authoring in the course — a customized "
                        + "guide replaces the house guide in the initialize instructions, and "
                        + "the initialize copy is frozen per connection while this resource "
                        + "always serves the live text."),
                "mimeType": .string("text/markdown"),
            ])
        }
        // The guides are not course-scoped: a subject with no enrolments yet
        // still sees them.
        guard !courseByID.isEmpty else {
            return .object(["resources": .array(docEntries(context: context) + guidanceEntries)])
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
        return .object(
            ["resources": .array(docEntries(context: context) + guidanceEntries + resources)])
    }

    // MARK: - Authoring-guide docs

    /// Listing entries for the constant-backed guides (always present) and the
    /// curated file-backed guides whose files exist on disk.
    private func docEntries(context: ToolContext) -> [JSONValue] {
        let inline: [JSONValue] = Self.inlineDocResources.map { doc in
            .object([
                "uri": .string(doc.uri),
                "name": .string(doc.name),
                "description": .string(doc.description),
                "mimeType": .string("text/markdown"),
            ])
        }
        let fileBacked: [JSONValue] = Self.docResources.compactMap { doc in
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
        return inline + fileBacked
    }

    private static func docPath(_ doc: DocResource, context: ToolContext) -> String {
        context.request.application.directory.workingDirectory + doc.relativePath
    }

    /// Reads a curated guide — constant-backed first, then file-backed — or
    /// throws the same "unknown resource" error the manifest path uses when
    /// the slug is unknown or the file is unreadable.
    private func readDoc(uri: String, context: ToolContext) async throws -> JSONValue {
        try await context.requireEligibleSubject(tool: "resources/read")
        if let inline = Self.inlineDocResources.first(where: { $0.uri == uri }) {
            return Self.textContents(uri: uri, text: inline.text)
        }
        guard let doc = Self.docResources.first(where: { $0.uri == uri }),
            let data = FileManager.default.contents(atPath: Self.docPath(doc, context: context)),
            let text = String(data: data, encoding: .utf8)
        else {
            throw MCPToolError.invalidArguments(
                tool: "resources/read", detail: "Unknown or inaccessible resource: \(uri)")
        }
        return Self.textContents(uri: uri, text: text)
    }

    /// Reads a course's authoring guidance. Resolved through the same
    /// `mcpCourseGuidance` scoping the listing and the initialize embedding
    /// use, so "not enrolled", "no authoring authority", "archived", and "no
    /// guidance set" all collapse into the manifest path's anti-enumeration
    /// "unknown resource" answer.
    private func readCourseGuidance(
        courseCode: String, uri: String, context: ToolContext
    ) async throws -> JSONValue {
        try await context.requireEligibleSubject(tool: "resources/read")
        let guidance = try await mcpCourseGuidance(forSubject: context.subject, db: context.db)
        guard let match = guidance.first(where: { $0.courseCode == courseCode }) else {
            throw MCPToolError.invalidArguments(
                tool: "resources/read", detail: "Unknown or inaccessible resource: \(uri)")
        }
        return Self.textContents(uri: uri, text: match.text)
    }

    /// The `resources/read` result envelope for a single markdown/text body.
    private static func textContents(uri: String, text: String) -> JSONValue {
        .object([
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
        if let courseCode = Self.courseGuidanceCode(fromURI: uri) {
            return try await readCourseGuidance(courseCode: courseCode, uri: uri, context: context)
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
