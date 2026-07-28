// APIServer/MCP/Transport/MCPCourseGuidance.swift
//
// Per-course authoring voice for the content MCP server.  Every course starts
// out on Chickadee's house authoring-voice guide; a course's instructors can
// take that text over on the instructor MCP panel and edit it into their own
// (`courses.mcp_instructions`, nil while the course is still inheriting).  At
// initialize the dispatcher resolves the connecting account's authorable
// courses and appends a labelled block for each course that has customized its
// voice — the house guide already carries the default, so an inheriting course
// adds nothing.  Advisory by design: it shapes authored prose and changes no
// tool behaviour or scope.

import Core
import Fluent
import Foundation

/// One course's effective authoring voice.
struct MCPCourseGuidance: Equatable, Sendable {
    let courseCode: String
    /// The voice guide in force for this course: the instructors' own text when
    /// they have customized it, otherwise Chickadee's default.
    let text: String
    /// False when `text` is the inherited default rather than course-authored.
    let isCustomized: Bool
}

extension MCPServerInstructions {
    /// The complete instructions string for a connection whose account can
    /// author in courses that have customized their voice.  Only customized
    /// courses contribute — an inheriting course is already covered by the
    /// house guide inside `text` — so a connection with no customizations gets
    /// exactly `text`, byte for byte.
    static func text(withCourseGuidance guidance: [MCPCourseGuidance]) -> String {
        let customized = guidance.filter(\.isCustomized)
        guard !customized.isEmpty else { return text }
        let header = """
            Course-specific authoring voice

            The courses below have replaced the authoring-voice guide above with their own. \
            When authoring content for one of these courses, follow that course's guide in \
            place of the house guide; the house guide still governs every other course.
            """
        let blocks = customized.map { "Course \($0.courseCode):\n\($0.text)" }
        return ([text, header] + blocks).joined(separator: "\n\n")
    }
}

/// Resolves the effective authoring voice of every course the token subject can
/// author in: the non-archived enrolled courses where the account holds a
/// per-course role of TA or higher (admins qualify through any enrollment,
/// matching `evaluateCourseWrite`'s bypass), in course-code order.  A course
/// that has not customized its voice comes back carrying the house default with
/// `isCustomized == false`.  An unknown subject resolves to nothing rather than
/// an error — initialize must succeed regardless.
func mcpCourseGuidance(forSubject subject: String, db: any Database) async throws -> [MCPCourseGuidance] {
    guard
        let user = try await APIUser.query(on: db)
            .filter(\.$username == subject)
            .first(),
        let userID = user.id
    else { return [] }
    return try await enrolledCoursesWithRoles(for: userID, on: db)
        .filter { user.isAdmin || $0.role >= .ta }
        .map { enrolled in
            MCPCourseGuidance(
                courseCode: enrolled.course.code,
                text: courseAuthoringVoice(enrolled.course),
                isCustomized: courseHasCustomAuthoringVoice(enrolled.course))
        }
}

/// The voice guide in force for `course`: its own text when customized, else
/// Chickadee's default.  The single resolver behind the MCP surfaces and the
/// instructor panel, so the text an instructor edits is the text agents get.
func courseAuthoringVoice(_ course: APICourse) -> String {
    let custom = (course.mcpInstructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return custom.isEmpty ? MCPServerInstructions.authoringVoice : custom
}

/// True when `course` carries its own voice guide rather than inheriting the
/// default.
func courseHasCustomAuthoringVoice(_ course: APICourse) -> Bool {
    !(course.mcpInstructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
