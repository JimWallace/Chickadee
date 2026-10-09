// APIServer/Routes/Web/InstructorDashboardRoutes+AIAgents.swift
//
// The access half of the instructor AI agents tab (`/instructor/mcp`; the
// authoring-voice half is in `InstructorDashboardRoutes+MCP.swift`). It says
// what a connected agent can reach in the active course, and records each
// staff member's attestation that they connect only a UW-licensed AI account
// for AI-assisted feedback (docs/ai-assisted-feedback.md §"The AI agents tab").
//
//   POST /instructor/mcp/attestation → record or withdraw (course staff, TA+)
//
// The attestation is recorded and audited. Nothing enforces it: the feedback
// tools do not read it. Chickadee cannot see which AI account an agent uses,
// so the record is the control, by decision of the maintainer.

import Core
import Fluent
import Vapor

extension InstructorDashboardRoutes {

    /// What the access section of the tab shows for `course`.
    func agentAccessFacts(
        course: APICourse?, viewer: APIUser, req: Request
    ) async throws -> AgentAccessFacts {
        guard let course, let courseID = course.id, course.aiFeedbackEnabled == true else {
            return AgentAccessFacts(feedbackOn: false)
        }
        let assignments = try await APIAssignment.query(on: req.db)
            .filter(\.$courseID == courseID)
            .filter(\.$aiFeedbackEnabled == true)
            .sort(\.$title)
            .all()
        var rows: [AgentFeedbackAssignmentRow] = []
        for assignment in assignments {
            let drafts = try await APIReflectionFeedback.query(on: req.db)
                .filter(\.$assignmentID == assignment.requireID())
                .filter(\.$stateRaw == APIReflectionFeedback.State.draft.rawValue)
                .count()
            rows.append(
                AgentFeedbackAssignmentRow(
                    title: assignment.title,
                    reviewURL: "/instructor/\(assignment.publicID)/feedback",
                    draftCount: drafts))
        }
        let enrollment = try await viewerEnrollment(viewer, courseID: courseID, on: req.db)
        let isStaff = (enrollment?.role ?? .student) >= .ta
        return AgentAccessFacts(
            feedbackOn: true,
            feedbackAssignments: rows,
            canAttest: isStaff && !course.isArchived,
            attestedAtISO: enrollment?.aiFeedbackAttestedAt.map(iso8601String))
    }

    // MARK: - POST /instructor/mcp/attestation

    @Sendable
    func saveAIFeedbackAttestation(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseID = courseState.activeCourseUUID,
            let course = try await APICourse.find(courseID, on: req.db),
            course.aiFeedbackEnabled == true
        else {
            return req.redirect(to: "/instructor/mcp?error=course")
        }
        // The attestation is about the viewer's own account, so it lives on
        // their own enrollment row: an admin who is not enrolled has none.
        try await requireCourseWriteAccess(caller: user, courseID: courseID, atLeast: .ta, db: req.db)
        guard let enrollment = try await viewerEnrollment(user, courseID: courseID, on: req.db) else {
            return req.redirect(to: "/instructor/mcp?error=enrollment")
        }

        struct AttestationForm: Content {
            /// "record" or "withdraw".
            let action: String
        }
        let recording = try req.content.decode(AttestationForm.self).action == "record"
        enrollment.aiFeedbackAttestedAt = recording ? Date() : nil
        try await enrollment.save(on: req.db)
        await AuditLogger.record(
            action: .aiFeedbackAttestationChanged,
            targetType: .course,
            targetID: courseID.uuidString,
            metadata: ["course_code": course.code, "attested": String(recording)],
            on: req)
        return req.redirect(to: "/instructor/mcp?saved=\(recording ? "attested" : "withdrawn")")
    }

    private func viewerEnrollment(
        _ user: APIUser, courseID: UUID, on db: any Database
    ) async throws -> APICourseEnrollment? {
        guard let userID = user.id else { return nil }
        return try await APICourseEnrollment.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$course.$id == courseID)
            .first()
    }
}

/// The access section of the instructor AI agents tab.
struct AgentAccessFacts: Encodable {
    /// True when the admin turned AI-assisted feedback on for the course.
    let feedbackOn: Bool
    /// The course's assignments with their own gate on.
    var feedbackAssignments: [AgentFeedbackAssignmentRow] = []
    /// True when the viewer is course staff in a course that is not archived,
    /// and so can record or withdraw the attestation.
    var canAttest = false
    /// When the viewer recorded the attestation; nil when not recorded.
    var attestedAtISO: String?
}

/// One assignment with AI-assisted feedback on, for the access section.
struct AgentFeedbackAssignmentRow: Encodable {
    let title: String
    let reviewURL: String
    /// Drafts that still wait for a person.
    let draftCount: Int
}
