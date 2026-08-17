// APIServer/MCP/Tools/MCPStudentDataBoundary.swift
//
// The single sanctioned access point from the MCP tool surface to the two
// student-data tables it must touch — submissions and results. Every accessor
// here hard-filters to the instructor's own VALIDATION runs
// (`kind == .validation`), so a student submission or grade is never reachable
// through MCP.
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
