// APIServer/MCP/Transport/MCPCourseGuidance.swift
//
// Per-course authoring guidance layered onto the content MCP server's
// `initialize` instructions.  Instructors write the text on the instructor MCP
// panel (courses.mcp_instructions); at initialize the dispatcher resolves the
// connecting account's authorable courses and appends each course's guidance
// under a labelled block, so an agent picks up the course's own tone and style
// preferences alongside the house authoring-voice guide.  Advisory by design —
// it shapes authored prose and changes no tool behaviour or scope.

import Core
import Fluent
import Foundation

/// One course's authoring guidance, as appended to the initialize instructions.
struct MCPCourseGuidance: Equatable, Sendable {
    let courseCode: String
    let text: String
}

extension MCPServerInstructions {
    /// The complete instructions string for a connection whose account can
    /// author in courses carrying custom guidance.  With no guidance this is
    /// exactly `text`, so accounts without any per-course text see the same
    /// bytes as before.
    static func text(withCourseGuidance guidance: [MCPCourseGuidance]) -> String {
        guard !guidance.isEmpty else { return text }
        let header = """
            Course-specific authoring guidance

            The instructors of the courses below have set additional guidance for content \
            authored in their course. It applies only when authoring in that course and \
            supplements the house authoring-voice guide above; where the two conflict, the \
            course's own guidance takes precedence for that course's content.
            """
        let blocks = guidance.map { "Course \($0.courseCode):\n\($0.text)" }
        return ([text, header] + blocks).joined(separator: "\n\n")
    }
}

/// Resolves the per-course guidance blocks for the token subject: the
/// non-archived courses the account is enrolled in with authoring authority
/// (per-course role of TA or higher; admins qualify through any enrollment,
/// matching `evaluateCourseWrite`'s bypass) whose `mcp_instructions` is
/// non-empty, in course-code order.  An unknown subject resolves to no
/// guidance rather than an error — initialize must succeed regardless.
func mcpCourseGuidance(forSubject subject: String, db: any Database) async throws -> [MCPCourseGuidance] {
    guard
        let user = try await APIUser.query(on: db)
            .filter(\.$username == subject)
            .first(),
        let userID = user.id
    else { return [] }
    return try await enrolledCoursesWithRoles(for: userID, on: db)
        .filter { user.isAdmin || $0.role >= .ta }
        .compactMap { enrolled in
            let text = (enrolled.course.mcpInstructions ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return MCPCourseGuidance(courseCode: enrolled.course.code, text: text)
        }
}
