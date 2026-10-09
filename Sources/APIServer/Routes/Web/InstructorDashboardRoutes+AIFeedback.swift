// APIServer/Routes/Web/InstructorDashboardRoutes+AIFeedback.swift
//
// The web half of AI-assisted feedback (docs/ai-assisted-feedback.md): the
// assignment gate, and the staff review page where every agent draft is read,
// edited and released, or discarded. Nothing reaches a student without a
// person's Release here.
//
//   POST /instructor/:assignmentID/ai-feedback        — the assignment gate (instructor)
//   GET  /instructor/:assignmentID/feedback           — the review page (TA+)
//   POST /instructor/:assignmentID/feedback           — save, release or discard (TA+)

import Core
import Fluent
import Vapor

extension InstructorDashboardRoutes {

    // MARK: - POST /instructor/:assignmentID/ai-feedback

    /// Saves the assignment gate. Refused while the course gate is off, so an
    /// instructor cannot switch the feature on ahead of the admin's approval.
    /// A lightweight endpoint, like the secret-reveal toggle: no manifest
    /// change, no regrade, no close.
    @Sendable
    func saveAIFeedbackSetting(req: Request) async throws -> Response {
        let assignment = try await loadAssignmentForWrite(req, atLeast: .instructor)
        struct ToggleBody: Content {
            // Checkbox: "on" when checked, absent from the body when not.
            var enabled: String?
        }
        let enabled = ((try? req.content.decode(ToggleBody.self))?.enabled) != nil
        let editURL = "/instructor/\(assignment.publicID)/edit"
        guard try await APICourse.find(assignment.courseID, on: req.db)?.aiFeedbackEnabled == true else {
            return req.redirect(
                to: "\(editURL)?error=AI-assisted+feedback+is+not+turned+on+for+this+course")
        }
        assignment.aiFeedbackEnabled = enabled
        try await assignment.save(on: req.db)
        await AuditLogger.record(
            action: .aiFeedbackAssignmentToggled,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: ["assignment": assignment.publicID, "enabled": String(enabled)],
            on: req
        )
        return req.redirect(to: "\(editURL)?notice=AI-assisted+feedback+setting+saved")
    }

    // MARK: - GET /instructor/:assignmentID/feedback

    /// Lists every student who has submitted, with their feedback state. A
    /// row that has feedback text also has a disclosure with the student's
    /// written answers and an editor; it opens by itself when the row still
    /// needs a person (a draft, or feedback the student has resubmitted since).
    @Sendable
    func feedbackReviewPage(req: Request) async throws -> View {
        let assignment = try await loadAssignmentForWrite(req, atLeast: .ta)
        guard let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db) else {
            throw Abort(.notFound)
        }
        let latest = try await ReflectionFeedbackService.latestStudentSubmissions(for: assignment, on: req.db)
        let rows = try await ReflectionFeedbackService.ensureRows(
            for: assignment, userIDs: latest.keys, on: req.db)
        let users = try await APIUser.query(on: req.db)
            .filter(\.$id ~~ Array(latest.keys))
            .all()

        var reviewRows: [FeedbackReviewRow] = []
        for user in users.sorted(by: { $0.username < $1.username }) {
            guard let userID = user.id, let row = rows[userID] else { continue }
            let submission = latest[userID]
            let state = ReflectionFeedbackService.displayState(of: row, latestSubmissionID: submission?.id)
            let hasText = row.draftText != nil && state != .discarded
            let reflections =
                hasText
                ? await ReflectionFeedbackService.reflections(setup: setup, submission: submission) : []
            reviewRows.append(
                FeedbackReviewRow(
                    handle: row.handle,
                    student: user.displayName ?? user.username,
                    username: user.username,
                    state: state.rawValue,
                    stateLabel: Self.feedbackStateLabel(state),
                    hasText: hasText,
                    needsReview: state == .draft || state == .stale,
                    draftText: row.draftText ?? "",
                    draftedBy: row.draftedByClient,
                    answers: reflections.map {
                        FeedbackReviewText(index: $0.index, paragraphs: ProseParagraphs.split($0.response ?? ""))
                    }))
        }
        let prompts = await ReflectionFeedbackService.reflections(setup: setup, submission: nil).map {
            FeedbackReviewText(index: $0.index, paragraphs: ProseParagraphs.split($0.prompt))
        }

        return try await req.view.render(
            "assignment-feedback",
            FeedbackReviewContext(
                currentUser: req.currentUserContext,
                assignmentID: assignment.publicID,
                assignmentTitle: assignment.title,
                gatesOpen: try await ReflectionFeedbackService.gatesOpen(assignment, on: req.db),
                prompts: prompts,
                rows: reviewRows,
                reviewCount: reviewRows.filter(\.needsReview).count,
                maxDraftLength: ReflectionFeedbackService.maxDraftLength,
                flashError: req.query[String.self, at: "error"],
                flashSuccess: req.query[String.self, at: "notice"]))
    }

    // MARK: - POST /instructor/:assignmentID/feedback

    /// Saves a person's review of one draft, named by `handle` in the body. `save` keeps it a draft (and
    /// withdraws it from the student if it was released); `release` makes the
    /// edited text visible to the student; `discard` hides it.
    @Sendable
    func saveFeedbackReview(req: Request) async throws -> Response {
        let assignment = try await loadAssignmentForWrite(req, atLeast: .ta)
        let caller = try req.auth.require(APIUser.self)
        struct ReviewBody: Content {
            var handle: String
            var action: String
            var feedback: String?
        }
        let pageURL = "/instructor/\(assignment.publicID)/feedback"
        let body = try req.content.decode(ReviewBody.self)
        let handle = body.handle
        guard
            let row = try await APIReflectionFeedback.query(on: req.db)
                .filter(\.$assignmentID == assignment.requireID())
                .filter(\.$handle == handle)
                .first()
        else {
            throw Abort(.notFound)
        }
        let text = body.feedback ?? ""

        switch body.action {
        case "discard":
            row.state = .discarded
            row.releasedAt = nil
            row.reviewedByUserID = caller.id
            try await row.save(on: req.db)
            await recordFeedbackReview(.aiFeedbackDiscarded, assignment: assignment, handle: handle, on: req)
            return req.redirect(to: "\(pageURL)?notice=Feedback+for+\(handle)+discarded")
        case "save", "release":
            if let refusal = ReflectionFeedbackService.refusal(forDraft: text) {
                return req.redirect(
                    to: "\(pageURL)?error=\(refusal.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
                )
            }
            row.draftText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            row.reviewedByUserID = caller.id
            if body.action == "release" {
                row.state = .released
                row.releasedAt = Date()
            } else {
                row.state = .draft
                row.releasedAt = nil
            }
            // The student's latest submission is what the reviewed text now
            // answers, so the row stops reading as stale.
            let latest = try await ReflectionFeedbackService.latestStudentSubmissions(for: assignment, on: req.db)
            row.submissionID = latest[row.userID]?.id ?? row.submissionID
            try await row.save(on: req.db)
            if body.action == "release" {
                await recordFeedbackReview(.aiFeedbackReleased, assignment: assignment, handle: handle, on: req)
                return req.redirect(to: "\(pageURL)?notice=Feedback+for+\(handle)+released")
            }
            return req.redirect(to: "\(pageURL)?notice=Draft+for+\(handle)+saved")
        default:
            throw Abort(.badRequest)
        }
    }

    private func recordFeedbackReview(
        _ action: AuditAction, assignment: APIAssignment, handle: String, on req: Request
    ) async {
        await AuditLogger.record(
            action: action,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: ["assignment": assignment.publicID, "handle": handle],
            on: req
        )
    }

    static func feedbackStateLabel(_ state: ReflectionFeedbackState) -> String {
        switch state {
        case .none: return "No draft"
        case .draft: return "Draft"
        case .released: return "Released"
        case .discarded: return "Discarded"
        case .stale: return "Resubmitted since"
        }
    }
}

struct FeedbackReviewContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentID: String
    let assignmentTitle: String
    /// False when either gate is off: the agent cannot read or draft, but the
    /// page still lets staff review what is already there.
    let gatesOpen: Bool
    /// The questions, once, from the starter notebook.
    let prompts: [FeedbackReviewText]
    let rows: [FeedbackReviewRow]
    /// Rows that still need a person: a draft, or a stale one.
    let reviewCount: Int
    let maxDraftLength: Int
    let flashError: String?
    let flashSuccess: String?
}

struct FeedbackReviewRow: Encodable {
    let handle: String
    let student: String
    let username: String
    let state: String
    let stateLabel: String
    /// True when the row has feedback text that is not discarded.
    let hasText: Bool
    /// True for a draft, or feedback written before a resubmission.
    let needsReview: Bool
    let draftText: String
    let draftedBy: String?
    let answers: [FeedbackReviewText]
}

/// A prompt or an answer, split into paragraphs so the page renders prose
/// without a preformatted block.
struct FeedbackReviewText: Encodable {
    let index: Int
    let paragraphs: [String]
}
