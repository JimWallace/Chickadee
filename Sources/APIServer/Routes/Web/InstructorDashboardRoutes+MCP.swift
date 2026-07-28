// APIServer/Routes/Web/InstructorDashboardRoutes+MCP.swift
//
// Instructor MCP panel: per-course authoring guidance for connected agents.
//
//   GET  /instructor/mcp   → instructor-mcp.leaf (view / edit the active course's guidance)
//   POST /instructor/mcp   → save (per-course instructor only) → redirect back with a flash
//
// The saved text (`courses.mcp_instructions`) is layered onto the content MCP
// server's `initialize` instructions for accounts with authoring authority in
// the course (MCP/Transport/MCPCourseGuidance.swift), so an instructor can set
// the tone agents use when authoring content for their course. Advisory
// voice/tone guidance only — it never changes tool behaviour or scopes.

import Core
import Fluent
import Foundation
import Vapor

extension InstructorDashboardRoutes {
    /// Server-side cap on the stored guidance. Generous for a page of prose,
    /// small enough that every `initialize` payload stays lightweight.
    static let mcpGuidanceMaxLength = 4000

    @Sendable
    func mcpPanelPage(req: Request) async throws -> View {
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
            readOnlyNote = "Only this course's instructors can edit its guidance."
        }

        let flashSuccess: String? =
            req.query[String.self, at: "saved"] != nil
            ? "Guidance saved. Connected agents pick it up the next time they connect." : nil
        let flashError: String? = {
            switch req.query[String.self, at: "error"] {
            case "length":
                return "Guidance is limited to \(Self.mcpGuidanceMaxLength) characters."
            case "course":
                return "No active course."
            default:
                return nil
            }
        }()

        let ctx = InstructorMCPContext(
            currentUser: try await req.courseAwareUserContext(),
            activeInstructorTab: "mcp",
            hasActiveCourse: course != nil,
            courseCode: course?.code ?? "",
            guidanceText: course?.mcpInstructions ?? "",
            houseVoiceGuide: MCPServerInstructions.authoringVoice,
            maxLength: Self.mcpGuidanceMaxLength,
            canEdit: canEdit,
            readOnlyNote: readOnlyNote,
            mcpDisabled: !req.application.appConfig.mcp.mode.isMounted,
            flashSuccess: flashSuccess,
            flashError: flashError)
        return try await req.view.render("instructor-mcp", ctx)
    }

    @Sendable
    func saveMCPGuidance(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseUUID = courseState.activeCourseUUID,
            let course = try await APICourse.find(courseUUID, on: req.db)
        else {
            return req.redirect(to: "/instructor/mcp?error=course")
        }
        // A course-level setting → per-course instructor floor (admin bypass,
        // archived-course block), scoped to the active course itself.
        try await requireCourseWriteAccess(
            caller: user, courseID: courseUUID, atLeast: .instructor, db: req.db)

        struct GuidanceForm: Content {
            let instructions: String?
        }
        let raw = (try req.content.decode(GuidanceForm.self).instructions ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count <= Self.mcpGuidanceMaxLength else {
            return req.redirect(to: "/instructor/mcp?error=length")
        }

        course.mcpInstructions = raw.isEmpty ? nil : raw
        try await course.save(on: req.db)
        // Audit the change without recording the text itself (the MCP surface
        // never logs content bodies); the length distinguishes set vs cleared.
        await AuditLogger.record(
            action: .mcpCourseInstructionsUpdated,
            targetType: .course,
            targetID: courseUUID.uuidString,
            metadata: ["course_code": course.code, "length": String(raw.count)],
            on: req)
        return req.redirect(to: "/instructor/mcp?saved=1")
    }
}
