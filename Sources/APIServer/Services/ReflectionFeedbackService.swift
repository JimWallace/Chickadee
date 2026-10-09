// APIServer/Services/ReflectionFeedbackService.swift
//
// The shared logic of AI-assisted feedback (docs/ai-assisted-feedback.md),
// used by the MCP feedback tools (through `MCPStudentDataBoundary`, which owns
// the MCP-side gate) and by the staff review and student pages.
//
// Nothing here checks who is asking. Every caller authorizes first, and the
// MCP path also checks both gates first.

import Core
import Fluent
import Foundation

/// The feedback state a person or an agent sees. `stale` is derived: a draft
/// or a release written against a submission that is no longer the
/// student's latest.
enum ReflectionFeedbackState: String, Codable, Sendable, CaseIterable {
    case none
    case draft
    case released
    case discarded
    case stale
}

enum ReflectionFeedbackService {
    /// The longest draft an agent or a person may save, in characters.
    static let maxDraftLength = 4000

    /// True when both gates are on: the course's (admin) and the
    /// assignment's (instructor).
    static func gatesOpen(_ assignment: APIAssignment, on db: any Database) async throws -> Bool {
        guard assignment.aiFeedbackEnabled == true else { return false }
        return try await APICourse.find(assignment.courseID, on: db)?.aiFeedbackEnabled == true
    }

    /// Each student's latest submission to the assignment, keyed by user.
    /// Validation runs, tournament copies and class aggregates are excluded:
    /// only `kind == student` rows with an owner count.
    static func latestStudentSubmissions(
        for assignment: APIAssignment, on db: any Database
    ) async throws -> [UUID: APISubmission] {
        let submissions = try await APISubmission.query(on: db)
            .filter(\.$testSetupID == assignment.testSetupID)
            .filter(\.$kind == APISubmission.Kind.student)
            .filter(\.$userID != nil)
            .sort(\.$submittedAt, .descending)
            .all()
        var latest: [UUID: APISubmission] = [:]
        for submission in submissions {
            guard let userID = submission.userID, latest[userID] == nil else { continue }
            latest[userID] = submission
        }
        return latest
    }

    /// The feedback rows for `userIDs`, creating any that are missing with a
    /// fresh random handle. A handle collision (one in about 600 million per
    /// pair) retries with a new draw.
    static func ensureRows(
        for assignment: APIAssignment, userIDs: some Collection<UUID>, on db: any Database
    ) async throws -> [UUID: APIReflectionFeedback] {
        let assignmentID = try assignment.requireID()
        var rows = Dictionary(
            try await APIReflectionFeedback.query(on: db)
                .filter(\.$assignmentID == assignmentID)
                .all()
                .map { ($0.userID, $0) },
            uniquingKeysWith: { first, _ in first })
        for userID in userIDs where rows[userID] == nil {
            rows[userID] = try await createRow(assignmentID: assignmentID, userID: userID, on: db)
        }
        return rows
    }

    private static func createRow(
        assignmentID: UUID, userID: UUID, on db: any Database
    ) async throws -> APIReflectionFeedback {
        var attempt = 0
        while true {
            let row = APIReflectionFeedback(
                assignmentID: assignmentID, userID: userID, handle: FeedbackHandle.random())
            do {
                try await row.create(on: db)
                return row
            } catch let error as any DatabaseError where error.isConstraintFailure && attempt < 4 {
                attempt += 1
                // A concurrent call may have made this student's row first.
                if let existing = try await APIReflectionFeedback.query(on: db)
                    .filter(\.$assignmentID == assignmentID)
                    .filter(\.$userID == userID)
                    .first()
                {
                    return existing
                }
            }
        }
    }

    /// The state a person or an agent sees for `row`.
    static func displayState(
        of row: APIReflectionFeedback, latestSubmissionID: String?
    ) -> ReflectionFeedbackState {
        switch row.state {
        case .none: return .none
        case .discarded: return .discarded
        case .draft, .released:
            if let written = row.submissionID, written != latestSubmissionID {
                return .stale
            }
            return row.state == .draft ? .draft : .released
        }
    }

    /// The prompt and response pairs of `submission`, against the starter
    /// notebook of `setup`. Empty when the starter tags no cell.
    static func reflections(
        setup: APITestSetup, submission: APISubmission?
    ) async -> [ReflectionPair] {
        guard let starter = try? await notebookData(for: setup) else { return [] }
        let submitted: Data? =
            if let submission { await submittedNotebook(submission) } else { nil }
        return ReflectionCells.pairs(starter: starter, submission: submitted)
    }

    /// The notebook a student submitted: the artifact itself when it is an
    /// `.ipynb`, else the notebook inside the zip. Nil when neither exists.
    static func submittedNotebook(_ submission: APISubmission) async -> Data? {
        let path = submission.zipPath
        let name = (submission.filename ?? path).lowercased()
        if name.hasSuffix(".ipynb") || path.lowercased().hasSuffix(".ipynb") {
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }
        return await extractNotebookFromZip(zipPath: path)
    }

    /// The released feedback written against `submission`, for its results
    /// page. Released text stays visible when a gate is later turned off: it
    /// is staff-reviewed content by then, not agent access.
    static func releasedFeedback(
        for submission: APISubmission, assignment: APIAssignment?, on db: any Database
    ) async throws -> String? {
        guard submission.kind == APISubmission.Kind.student,
            let userID = submission.userID,
            let assignmentID = assignment?.id,
            let row = try await APIReflectionFeedback.query(on: db)
                .filter(\.$assignmentID == assignmentID)
                .filter(\.$userID == userID)
                .first(),
            row.state == .released, row.submissionID == submission.id
        else { return nil }
        return row.draftText
    }

    /// Validates draft text for saving: trimmed, not empty, and no longer
    /// than `maxDraftLength`. Returns the reason when the text is refused.
    static func refusal(forDraft text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "The feedback text is empty." }
        if trimmed.count > maxDraftLength {
            return "The feedback text is \(trimmed.count) characters; the limit is \(maxDraftLength)."
        }
        return nil
    }
}
