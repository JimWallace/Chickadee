// APIServer/Routes/Web/WebRoutes+CompositeSpare.swift
//
// POST /testsetups/:testSetupID/composite/spare — "Fill a hole" on the result
// page (docs/class-composite.md, slice 6b). A student whose tile passed asks
// the server to grade that code again for an empty slot. The request passes
// the same gates as a submission: enrolment, an open assignment and an open
// session window. It returns to the result page with a fixed message.

import Core
import Fluent
import Foundation
import Vapor

extension WebRoutes {

    @Sendable
    func requestCompositeSpare(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let userID = try user.requireID()
        guard let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else { throw Abort(.notFound) }
        let back = try await spareReturnPath(req: req, userID: userID)

        let assignment: APIAssignment?
        do {
            assignment = try await requireOpenStudentAssignment(for: setupID, user: user, gate: .submission, on: req)
        } catch is AssignmentSubmissionGateError {
            return req.redirect(to: back + "?spare=\(SpareFlash.closed.rawValue)")
        }
        guard let assignment else { throw Abort(.notFound) }

        let answer: SpareFlash
        do {
            _ = try await CompositeSpares.request(
                assignment: assignment, setup: setup, userID: userID, app: req.application, on: req.db)
            answer = .queued
        } catch let error as CompositeSpares.RequestError {
            switch error {
            case .notComposite: throw Abort(.notFound)
            case .noPassingTile: answer = .noTile
            case .inFlight: answer = .grading
            case .noHole: answer = .noHole
            case .unavailable: answer = .unavailable
            }
        }
        return req.redirect(to: back + "?spare=\(answer.rawValue)")
    }

    /// The student's own result page that sent the request, or the dashboard.
    private func spareReturnPath(req: Request, userID: UUID) async throws -> String {
        guard let submissionID = try? await req.decodeContent(SpareForm.self).submissionID,
            let submission = try await APISubmission.find(submissionID, on: req.db),
            submission.userID == userID
        else { return "/" }
        return "/submissions/\(submissionID)"
    }
}

/// The "Fill a hole" form: the result page it was sent from.
private struct SpareForm: Decodable {
    let submissionID: String?
}
