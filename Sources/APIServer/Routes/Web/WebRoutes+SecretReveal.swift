// APIServer/Routes/Web/WebRoutes+SecretReveal.swift
//
// Student "spend your secret-reveal token" endpoint.
//
//   POST /testsetups/:testSetupID/reveal-secret
//
// Spending is permanent from the student's side (the form carries a JS
// confirm); course staff can re-grant from the assignment roster
// (`regrantSecretRevealToken` in InstructorDashboardRoutes+StudentActions).
// The spend row unlocks itemized secret-tier results across all of the
// student's submissions for the assignment — display only, grades are
// unaffected (they already span every tier).

import Fluent
import Vapor

extension WebRoutes {

    /// Handles the spend POST. Refusals redirect back without writing a row:
    /// the offer form only renders when the spend is allowed, so a refused
    /// POST is either a stale page or hand-crafted — never worth burning the
    /// student's token over (e.g. an assignment with no secret tests has
    /// nothing to reveal).
    @Sendable
    func spendSecretRevealToken(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.unauthorized) }
        guard
            let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        // Cross-tenant guard: only members of the setup's course may interact
        // with it (same gate as the submit form).
        try await requireCourseEnrollment(caller: user, courseID: setup.courseID, db: req.db)

        guard
            let assignment = try await APIAssignment.query(on: req.db)
                .filter(\.$testSetupID == setupID)
                .first(),
            let assignmentID = assignment.id
        else {
            throw Abort(.notFound)
        }

        let redirectTarget = try await spendRedirectTarget(
            req: req, setupID: setupID, userID: userID)

        // All three gates mirror the offer-rendering conditions on the
        // submission page. Staff spending is refused (their view already
        // itemizes every tier; a spend row would only corrupt the roster).
        let isStaff = try await isCourseStaff(user, inCourse: setup.courseID, db: req.db)
        guard
            assignment.secretRevealEnabled == true,
            !isStaff,
            hasSecretTierTests(setup.decodedManifest())
        else {
            return req.redirect(to: redirectTarget)
        }

        try await SecretRevealStore.spendToken(
            userID: userID, assignmentID: assignmentID, on: req.db)
        await AuditLogger.record(
            action: .secretRevealSpent,
            targetType: .assignment,
            targetID: assignmentID.uuidString,
            metadata: ["assignment": assignment.publicID],
            on: req)
        req.logger.info(
            "secret_reveal_spent assignment=\(assignment.publicID) student=\(userID.uuidString)")
        return req.redirect(to: redirectTarget)
    }

    /// Where to land after the POST: the submission page the form was on
    /// (validated — must exist, belong to this setup, and be the caller's
    /// own), else the setup's submission history.
    private func spendRedirectTarget(
        req: Request, setupID: String, userID: UUID
    ) async throws -> String {
        struct SpendBody: Content {
            var submissionID: String?
        }
        let body = try? req.content.decode(SpendBody.self)
        if let submissionID = body?.submissionID,
            let submission = try await APISubmission.find(submissionID, on: req.db),
            submission.testSetupID == setupID,
            submission.userID == userID
        {
            return "/submissions/\(submissionID)"
        }
        return "/testsetups/\(setupID)/history"
    }
}
