// APIServer/Routes/Web/InstructorDashboardRoutes+MCP.swift
//
// Instructor AI agents tab: what a connected agent can reach in the active
// course (InstructorDashboardRoutes+AIAgents.swift), and the course's
// authoring voice for connected agents.
//
//   GET  /instructor/mcp   → InstructorMCPPage (access, attestation, voice guide)
//   POST /instructor/mcp   → save or reset (per-course instructor only) → redirect with a flash
//
// One editable guide per course, seeded from Chickadee's house authoring-voice
// guide: the box starts out showing the default, and saving an edited copy
// takes the course off the default (`courses.mcp_instructions`, nil while
// inheriting). The content MCP server serves each course's effective guide to
// agents authoring in it (MCP/Transport/MCPCourseGuidance.swift). Advisory
// voice/tone guidance only — it never changes tool behaviour or scopes.

import Core
import Elementary
import Fluent
import Foundation
import Vapor

extension InstructorDashboardRoutes {
    /// Server-side cap on the stored guide. Roomy next to the ~2 KB default so
    /// an instructor can expand on it, small enough that every `initialize`
    /// payload stays lightweight.
    static let mcpGuidanceMaxLength = 8000

    @Sendable
    func mcpPanelPage(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)

        var course: APICourse?
        if let courseUUID = courseState.activeCourseUUID {
            course = try await APICourse.find(courseUUID, on: req.db)
        }
        let isArchived = course?.isArchived ?? false
        let holdsInstructorRole = user.isAdmin || (courseState.active?.role ?? .student) >= .instructor
        let canEdit = holdsInstructorRole && !isArchived

        let readOnlyNote: String?
        if canEdit {
            readOnlyNote = nil
        } else if isArchived {
            readOnlyNote = "This course is archived and is read-only."
        } else {
            readOnlyNote = "Only this course's instructors can edit its authoring voice."
        }

        let flashSuccess: String? = {
            switch req.query[String.self, at: "saved"] {
            case "1":
                return "Saved. Connected agents pick it up the next time they connect."
            case "reset":
                return "Reset to the Chickadee default."
            case "attested":
                return "Recorded."
            case "withdrawn":
                return "Withdrawn."
            default:
                return nil
            }
        }()
        let flashError: String? = {
            switch req.query[String.self, at: "error"] {
            case "length":
                return "The guide is limited to \(Self.mcpGuidanceMaxLength) characters."
            case "course":
                return "No active course."
            case "enrollment":
                return "Only course staff enrolled in this course can record this."
            default:
                return nil
            }
        }()

        let isCustomized = course.map(courseHasCustomAuthoringVoice) ?? false
        let guidanceText = course.map(courseAuthoringVoice) ?? MCPServerInstructions.authoringVoice
        let agentAccess = try await agentAccessFacts(course: course, viewer: user, req: req)
        let page = try await PageRequestContext.courseAware(req)
        return try await HTMLResponse {
            InstructorMCPPage(
                page: page,
                flash: FlashMessages(success: flashSuccess, error: flashError),
                hasActiveCourse: course != nil,
                courseCode: course?.code ?? "",
                guidanceText: guidanceText,
                guidanceLength: guidanceText.count,
                isCustomized: isCustomized,
                showResetButton: canEdit && isCustomized,
                sourceNote: isCustomized ? "Customized" : "Chickadee default",
                maxLength: Self.mcpGuidanceMaxLength,
                canEdit: canEdit,
                readOnlyNote: readOnlyNote,
                mcpDisabled: !req.application.appConfig.mcp.mode.isMounted,
                agentAccess: agentAccess)
        }.encodeResponse(for: req)
    }

    @Sendable
    func saveMCPGuidance(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        // A course-level setting → per-course instructor floor (admin bypass,
        // archived-course block), scoped to the active course itself.
        guard let course = try await req.activeCourseForWrite(user, atLeast: .instructor) else {
            return req.redirect(to: "/instructor/mcp?error=course")
        }
        let courseUUID = try course.requireID()

        struct GuidanceForm: Content {
            let instructions: String?
            /// "reset" from the Reset button; absent for a normal save.
            let action: String?
        }
        let form = try await req.decodeContent(GuidanceForm.self)
        // Browsers submit textarea content with CRLF line endings; normalize so
        // stored text (and the compare against the default below) is \n-only.
        let raw = (form.instructions ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count <= Self.mcpGuidanceMaxLength else {
            return req.redirect(to: "/instructor/mcp?error=length")
        }

        // The course inherits the default again when it is explicitly reset,
        // when the box is emptied, or when the submitted text still matches the
        // default verbatim — storing an unedited copy would only freeze the
        // course against future changes to the house guide.
        let isReset = form.action == "reset"
        let matchesDefault =
            raw == MCPServerInstructions.authoringVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        let inherits = isReset || raw.isEmpty || matchesDefault
        course.mcpInstructions = inherits ? nil : raw
        try await course.save(on: req.db)
        // Audit the change without recording the text itself (the MCP surface
        // never logs content bodies); the length distinguishes edit vs inherit.
        await AuditLogger.record(
            action: .mcpCourseInstructionsUpdated,
            targetType: .course,
            targetID: courseUUID.uuidString,
            metadata: [
                "course_code": course.code,
                "length": String(inherits ? 0 : raw.count),
                "source": inherits ? "default" : "course",
            ],
            on: req)
        return req.redirect(to: inherits ? "/instructor/mcp?saved=reset" : "/instructor/mcp?saved=1")
    }
}
