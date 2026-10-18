// APIServer/Routes/Web/WebRoutes+Sessions.swift
//
// The sessions of per-group class activities (docs/lab-groups.md, slice 2).
//
//   POST /testsetups/:testSetupID/sessions/start  → start or reopen a group's session (course staff)
//   POST /testsetups/:testSetupID/sessions/end    → end it (course staff)
//   GET  /join                                    → JoinSessionPage
//   POST /join                                    → join the session a code names, then go to its assignment
//
// Staff start and end sessions from the present page, so a TA can run their
// own lab: the floor is `.ta`, in a course that is not archived. A student
// joins by code alone; the code names one session in the deployment.

import Core
import Elementary
import Fluent
import Foundation
import Vapor

extension WebRoutes {

    private struct SessionForm: Content {
        var groupID: String?
    }

    private struct JoinForm: Content {
        var code: String?
    }

    func registerSessionRoutes(on routes: any RoutesBuilder) {
        routes.post("testsetups", ":testSetupID", "sessions", "start", use: startGroupSession)
        routes.post("testsetups", ":testSetupID", "sessions", "end", use: endGroupSession)
        routes.get("join", use: joinSessionPage)
        routes.post("join", use: joinSession)
    }

    @Sendable
    func startGroupSession(req: Request) async throws -> Response {
        let (user, assignment, groupID) = try await requireSessionControl(req)
        let now = Date()
        let session = try await ActivitySessionStore.open(
            assignmentID: assignment.requireID(), groupID: groupID, by: user.id, now: now, on: req.db)
        // A Start on an open session changes nothing, so it is not audited.
        if session.openedAt == now {
            await recordSessionChange(assignment, session: session, change: "started", on: req)
        }
        return req.redirect(to: presentPath(assignment, groupID: groupID))
    }

    @Sendable
    func endGroupSession(req: Request) async throws -> Response {
        let (_, assignment, groupID) = try await requireSessionControl(req)
        if let session = try await ActivitySessionStore.session(
            assignmentID: assignment.requireID(), groupID: groupID, on: req.db),
            session.closedAt == nil
        {
            try await ActivitySessionStore.close(session, on: req.db)
            await recordSessionChange(assignment, session: session, change: "ended", on: req)
        }
        return req.redirect(to: presentPath(assignment, groupID: groupID))
    }

    @Sendable
    func joinSessionPage(req: Request) async throws -> Response {
        _ = try req.auth.require(APIUser.self)
        return try await HTMLResponse {
            JoinSessionPage(page: PageRequestContext(request: req))
        }.encodeResponse(for: req)
    }

    @Sendable
    func joinSession(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let form = try await req.decodeContent(JoinForm.self)
        do {
            let session = try await ActivitySessionStore.join(
                code: form.code ?? "", userID: user.requireID(), on: req.db)
            guard let assignment = try await APIAssignment.find(session.assignmentID, on: req.db),
                let course = try await APICourse.find(assignment.courseID, on: req.db)
            else { throw Abort(.notFound) }
            return req.redirect(
                to: VanityURLRoutes.vanityPath(courseCode: course.urlKey, assignmentSlug: assignment.slug))
        } catch let error as ActivitySessionError {
            return try await HTMLResponse {
                JoinSessionPage(page: PageRequestContext(request: req), error: error.description, code: form.code ?? "")
            }.encodeResponse(for: req)
        }
    }

    // MARK: - Helpers

    /// The caller, the per-group activity's assignment and the group a
    /// start or end names, after the caller is authorized: a TA or above of
    /// the assignment's course, which is not archived. The caller is
    /// authorized first, so a 404 tells no one else whether the activity runs
    /// per group. The group must be in the course's first set, the only set
    /// that sessions read.
    private func requireSessionControl(_ req: Request) async throws -> (APIUser, APIAssignment, UUID) {
        let user = try req.auth.require(APIUser.self)
        guard let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else { throw Abort(.notFound) }
        try await requireCourseWriteAccess(caller: user, courseID: setup.courseID, atLeast: .ta, db: req.db)
        guard setup.decodedManifest()?.activity?.runsPerGroup == true,
            let assignment = try await assignmentByTestSetupID(setupID, on: req.db)
        else { throw Abort(.notFound) }
        let form = try await req.decodeContent(SessionForm.self)
        guard let groupID = form.groupID.flatMap(UUID.init(uuidString:)),
            let group = try await APICourseGroup.find(groupID, on: req.db),
            group.removedAt == nil,
            try await CourseGroupStore.sets(courseID: setup.courseID, on: req.db).first?.id == group.setID
        else { throw Abort(.notFound) }
        return (user, assignment, groupID)
    }

    private func recordSessionChange(
        _ assignment: APIAssignment, session: APIActivitySession, change: String, on req: Request
    ) async {
        await AuditLogger.record(
            action: .activityGroupSessionChanged,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: [
                "assignment": assignment.publicID,
                "group": session.groupID.uuidString,
                "change": change,
            ],
            on: req
        )
    }

    private func presentPath(_ assignment: APIAssignment, groupID: UUID) -> String {
        "/testsetups/\(assignment.testSetupID)/leaderboard?present=1&group=\(groupID.uuidString)"
    }
}
