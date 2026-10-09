// APIServer/MCP/Tools/MCPStudentDataBoundary.swift
//
// The single sanctioned access point from the MCP tool surface to the two
// student-data tables it must touch — submissions and results. Every accessor
// in the main enum hard-filters to the instructor's own VALIDATION runs
// (`kind == .validation`), so a student submission or grade is never reachable
// through them.
//
// The one exception is the gated feedback extension at the foot of this file
// (docs/ai-assisted-feedback.md). It reaches students' written reasoning, and
// nothing else of theirs, and only in an assignment whose course gate (an
// admin) and assignment gate (an instructor) are both on. No MCP tool can set
// either gate. It hands the tools pseudonymous handles, never a user id, and
// never a grade, a result, code or a name.
//
// This is the architectural form of the "student-data wall". MCP tool handlers
// must reach validation submissions/results ONLY through these accessors and
// must not query `APISubmission` / `APIResult` (or any other student-data
// model) directly. `MCPStudentDataWallTests` scans the tool sources and fails
// the build if a handler names a student-data model, so the
// `kind == .validation` filter cannot be forgotten or bypassed by a future
// tool. (The shared `loadExistingSolution` resolver, which lives outside the
// tool surface in the web routes layer, applies the same filter for the
// solution-notebook tools.)

import Core
import Fluent
import Foundation

enum MCPStudentDataBoundary {
    /// The assignment's reference-solution VALIDATION submission: the linked one
    /// if it is still a validation submission, else the most recent validation
    /// submission for the setup. Never returns a student submission.
    static func validationSubmission(
        for assignment: APIAssignment, on db: any Database
    ) async throws -> APISubmission? {
        if let validationID = assignment.validationSubmissionID,
            let linked = try await APISubmission.find(validationID, on: db),
            linked.kind == APISubmission.Kind.validation
        {
            return linked
        }
        return try await APISubmission.query(on: db)
            .filter(\.$testSetupID == assignment.testSetupID)
            .filter(\.$kind == APISubmission.Kind.validation)
            .sort(\.$submittedAt, .descending)
            .first()
    }

    /// Resolves a submission strictly by its stored ID, returning it only when it
    /// is a validation submission. Used to derive validation-run progress from
    /// the assignment's own `validationSubmissionID`; never yields a student row.
    static func validationSubmission(
        byID id: String, on db: any Database
    ) async throws -> APISubmission? {
        guard let submission = try await APISubmission.find(id, on: db),
            submission.kind == APISubmission.Kind.validation
        else { return nil }
        return submission
    }

    /// The most recent stored result for a submission obtained from one of the
    /// accessors above, so it only ever reflects the reference-solution run.
    static func latestResult(
        forSubmissionID submissionID: String, on db: any Database
    ) async throws -> APIResult? {
        try await APIResult.query(on: db)
            .filter(\.$submissionID == submissionID)
            .sort(\.$receivedAt, .descending)
            .first()
    }

    /// A validation variant's most recent result (multi-variant validation).
    /// The variant row stores the submission id of one `kind == .validation`
    /// run; resolving it back through the validation filter means this can
    /// never yield a student row, even from a corrupted variant record.
    static func variantResult(
        for variant: ValidationVariant, on db: any Database
    ) async throws -> APIResult? {
        guard let submissionID = variant.submissionID,
            let submission = try await validationSubmission(byID: submissionID, on: db),
            let id = submission.id
        else { return nil }
        return try await latestResult(forSubmissionID: id, on: db)
    }
}

// MARK: - Gated feedback access (docs/ai-assisted-feedback.md)

/// One student, as the feedback tools see them: a handle and a state. The
/// boundary keeps the user id and the submission on this side.
struct MCPFeedbackSubject: Sendable {
    let handle: String
    let state: ReflectionFeedbackState
    let draftText: String?
    let hasSubmission: Bool
}

extension MCPStudentDataBoundary {
    /// The test setup of an assignment a feedback tool has already authorized
    /// (course staff, TA+, in a course that is not archived), once both gates
    /// are confirmed on. Every feedback tool calls this before any other
    /// accessor here.
    static func gatedFeedbackSetup(
        for assignment: APIAssignment, on db: any Database
    ) async throws -> APITestSetup {
        guard try await ReflectionFeedbackService.gatesOpen(assignment, on: db) else {
            throw MCPToolError.invalidArguments(
                detail: "AI-assisted feedback is not turned on for assignment \"\(assignment.publicID)\". "
                    + "A deployment admin turns it on for the course, and then an instructor turns it on "
                    + "for the assignment, on the web. No MCP tool can turn it on.")
        }
        guard let setup = try await APITestSetup.find(assignment.testSetupID, on: db) else {
            throw MCPToolError.invalidArguments(detail: "The assignment's test setup could not be found.")
        }
        return setup
    }

    /// Every student who has submitted to a gated assignment, by handle.
    static func feedbackSubjects(
        for assignment: APIAssignment, on db: any Database
    ) async throws -> [MCPFeedbackSubject] {
        let latest = try await ReflectionFeedbackService.latestStudentSubmissions(for: assignment, on: db)
        let rows = try await ReflectionFeedbackService.ensureRows(
            for: assignment, userIDs: latest.keys, on: db)
        return latest.keys.compactMap { userID in
            rows[userID].map { subject(row: $0, latestSubmissionID: latest[userID]?.id) }
        }
        .sorted { $0.handle < $1.handle }
    }

    /// One student's handle, state and reflections in a gated assignment.
    /// Throws the same refusal for an unknown handle and for a handle of
    /// another assignment.
    static func feedbackReflections(
        handle: String, assignment: APIAssignment, setup: APITestSetup, on db: any Database
    ) async throws -> (subject: MCPFeedbackSubject, reflections: [ReflectionPair]) {
        let row = try await feedbackRow(handle: handle, assignment: assignment, on: db)
        let latest = try await ReflectionFeedbackService.latestStudentSubmissions(for: assignment, on: db)
        let submission = latest[row.userID]
        let reflections = await ReflectionFeedbackService.reflections(setup: setup, submission: submission)
        return (subject(row: row, latestSubmissionID: submission?.id), reflections)
    }

    /// Saves draft text for one handle against the student's latest
    /// submission. Refuses released feedback that is still current: course
    /// staff discard it on the web first. Never releases anything.
    static func saveFeedbackDraft(
        handle: String, text: String, assignment: APIAssignment,
        clientName: String?, on db: any Database
    ) async throws -> MCPFeedbackSubject {
        let row = try await feedbackRow(handle: handle, assignment: assignment, on: db)
        let latest = try await ReflectionFeedbackService.latestStudentSubmissions(for: assignment, on: db)
        guard let submissionID = latest[row.userID]?.id else {
            throw MCPToolError.invalidArguments(detail: "Student \(handle) has no submission to give feedback on.")
        }
        if ReflectionFeedbackService.displayState(of: row, latestSubmissionID: submissionID) == .released {
            throw MCPToolError.invalidArguments(
                detail: "Feedback for \(handle) is already released. Course staff must discard it "
                    + "on the review page before a new draft can replace it.")
        }
        row.draftText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        row.state = .draft
        row.submissionID = submissionID
        row.draftedAt = Date()
        row.draftedByClient = clientName
        row.reviewedByUserID = nil
        row.releasedAt = nil
        try await row.save(on: db)
        return subject(row: row, latestSubmissionID: submissionID)
    }

    private static func feedbackRow(
        handle: String, assignment: APIAssignment, on db: any Database
    ) async throws -> APIReflectionFeedback {
        guard FeedbackHandle.isWellFormed(handle),
            let row = try await APIReflectionFeedback.query(on: db)
                .filter(\.$assignmentID == assignment.requireID())
                .filter(\.$handle == handle)
                .first()
        else {
            throw MCPToolError.invalidArguments(
                detail: "No student with handle \"\(handle)\" in this assignment. "
                    + "Call list_reflections for the handles.")
        }
        return row
    }

    private static func subject(
        row: APIReflectionFeedback, latestSubmissionID: String?
    ) -> MCPFeedbackSubject {
        MCPFeedbackSubject(
            handle: row.handle,
            state: ReflectionFeedbackService.displayState(of: row, latestSubmissionID: latestSubmissionID),
            draftText: row.draftText,
            hasSubmission: latestSubmissionID != nil)
    }
}
