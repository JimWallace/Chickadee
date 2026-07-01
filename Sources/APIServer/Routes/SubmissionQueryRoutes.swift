// APIServer/Routes/SubmissionQueryRoutes.swift
//
// Phase 3: student-facing read endpoints.
//
//   GET /api/v1/submissions                   — list submissions
//   GET /api/v1/submissions/:id               — submission status
//   GET /api/v1/submissions/:id/results       — grading results (with optional tier filter)

import Core
import Fluent
import Foundation
import Vapor

struct SubmissionQueryRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let subs = routes.grouped("api", "v1", "submissions")
        subs.get(use: listSubmissions)
        subs.get(":submissionID", use: getSubmission)
        subs.get(":submissionID", "results", use: getResults)
    }

    // MARK: - GET /api/v1/submissions

    @Sendable
    func listSubmissions(req: Request) async throws -> SubmissionListResponse {
        let caller = try req.auth.require(APIUser.self)

        // Pagination: ?limit= (default 500, clamped to 1...5000) and
        // ?offset= (default 0, min 0), newest-first.
        let limit = min(max(req.query[Int.self, at: "limit"] ?? 500, 1), 5000)
        let offset = max(req.query[Int.self, at: "offset"] ?? 0, 0)

        var query = APISubmission.query(on: req.db)
            .filter(\.$kind == APISubmission.Kind.student)
            .sort(\.$submittedAt, .descending)

        // A non-admin sees others' submissions only for a test setup whose
        // course they staff; otherwise (including with no setup filter) they see
        // only their own (#417 Slice G — was the global `caller.isInstructor`).
        var callerIsCourseStaff = false
        if let testSetupID = req.query[String.self, at: "testSetupID"] {
            query = query.filter(\.$testSetupID == testSetupID)
            if let setup = try await APITestSetup.find(testSetupID, on: req.db) {
                callerIsCourseStaff = try await isCourseStaff(
                    caller, inCourse: setup.courseID, db: req.db)
            }
        }
        if !callerIsCourseStaff {
            query = query.filter(\.$userID == caller.id)
        }

        let submissions = try await query.range(offset..<(offset + limit)).all()
        return SubmissionListResponse(
            submissions: submissions.map(SubmissionSummary.init)
        )
    }

    // MARK: - GET /api/v1/submissions/:id

    @Sendable
    func getSubmission(req: Request) async throws -> SubmissionStatusResponse {
        let caller = try req.auth.require(APIUser.self)
        guard
            let subID = req.parameters.get("submissionID"),
            let submission = try await APISubmission.find(subID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        guard try await submissionAccess(caller: caller, submission: submission, on: req.db).canView
        else {
            throw Abort(.forbidden)
        }
        return SubmissionStatusResponse(submission: submission)
    }

    // MARK: - GET /api/v1/submissions/:id/results

    @Sendable
    func getResults(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        guard
            let subID = req.parameters.get("submissionID"),
            let submission = try await APISubmission.find(subID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        let access = try await submissionAccess(caller: caller, submission: submission, on: req.db)
        guard access.canView else {
            throw Abort(.forbidden)
        }

        guard
            let result = try await APIResult.query(on: req.db)
                .filter(\.$submissionID == subID)
                .sort(\.$receivedAt, .descending)
                .first()
        else {
            throw AppError.notFound(resource: "Results for submission '\(subID)' (none available yet)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard
            let data = result.collectionJSON.data(using: .utf8),
            let fullCollection = try? decoder.decode(TestOutcomeCollection.self, from: data)
        else {
            throw AppError.internalFailure(reason: "Stored result is corrupt")
        }

        // `fullCollection` carries the real grade across every tier.  The caller
        // may only *inspect* certain outcomes: secret never, release after the
        // deadline (instructors see all tiers).  Release is gated on the
        // *effective* deadline — the later of the assignment due date and the
        // caller's own per-student extension — so an accommodated student does
        // not get release output revealed while their extended window is still
        // open.  A non-instructor caller can only reach their own submission
        // (`canViewSubmission`), so the caller is the submission owner; for
        // instructors the deadline is unused (they see every tier).
        let assignment = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == submission.testSetupID)
            .first()
        let releaseDeadline = try await releaseVisibilityDeadline(
            for: assignment, user: caller, on: req.db)
        let visible = fullCollection.filtering(
            tiers: visibleTiers(isStaff: access.isStaff, effectiveDueAt: releaseDeadline))

        let responseCollection: TestOutcomeCollection
        if let tiersParam = req.query[String.self, at: "tiers"] {
            // Explicit tier slice (?tiers=public,release): return a
            // self-consistent sub-collection — aggregates recomputed over the
            // requested ∩ visible tiers.
            let requested = Set(tiersParam.split(separator: ",").map(String.init))
            responseCollection = visible.filtering(tiers: requested)
        } else {
            // Default: aggregates report the full all-tier grade (matching the
            // dashboard and submission page), while `outcomes` lists only the
            // results the caller may inspect.  The counts can exceed
            // `outcomes.count` — the intended "real grade, partial detail" shape,
            // identical to the web view.
            responseCollection = fullCollection.replacingOutcomes(with: visible.outcomes)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let responseData = try encoder.encode(responseCollection)

        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: responseData)
        )
    }
}

/// Per-course view authorization for a single submission (#417 Slice G).
/// Returns whether `caller` may view it and whether they view it as course
/// staff — the owner always may (`isStaff == false`), and a staff member (TA+
/// or admin) of the submission's course sees it with instructor-level tier
/// visibility. Resolving the course once lets the caller reuse `isStaff` for
/// tier filtering without a second lookup.
private func submissionAccess(
    caller: APIUser, submission: APISubmission, on db: Database
) async throws -> (canView: Bool, isStaff: Bool) {
    let isStaff = try await isSubmissionStaff(caller, submission: submission, on: db)
    return (isStaff || submission.userID == caller.id, isStaff)
}

// MARK: - Response types

struct SubmissionListResponse: Content {
    let submissions: [SubmissionSummary]
}

struct SubmissionSummary: Content {
    let submissionID: String
    let testSetupID: String
    let status: String
    let attemptNumber: Int
    let submittedAt: Date?

    init(_ submission: APISubmission) {
        self.submissionID = submission.id ?? ""
        self.testSetupID = submission.testSetupID
        self.status = submission.status
        self.attemptNumber = submission.attemptNumber ?? 1
        self.submittedAt = submission.submittedAt
    }
}

struct SubmissionStatusResponse: Content {
    let submissionID: String
    let testSetupID: String
    let status: String
    let attemptNumber: Int
    let submittedAt: Date?
    let assignedAt: Date?

    init(submission: APISubmission) {
        self.submissionID = submission.id ?? ""
        self.testSetupID = submission.testSetupID
        self.status = submission.status
        self.attemptNumber = submission.attemptNumber ?? 1
        self.submittedAt = submission.submittedAt
        self.assignedAt = submission.assignedAt
    }
}
