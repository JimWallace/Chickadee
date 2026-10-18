// APIServer/Routes/Web/WebRoutes+Sessions.swift
//
// The sessions of per-group class activities (docs/lab-groups.md, slice 2).
//
//   POST /testsetups/:testSetupID/sessions/start  → start or reopen a group's session (course staff)
//   POST /testsetups/:testSetupID/sessions/end    → end it (course staff)
//   GET  /testsetups/:testSetupID/sessions/attendance → SessionAttendancePage (course staff)
//   POST /testsetups/:testSetupID/sessions/remove → take a student out of the session (course staff)
//   GET  /join                                    → JoinSessionPage
//   POST /join                                    → join the session a code names, then go to its assignment
//
// Staff start and end sessions from the present page, so a TA can run their
// own lab: the floor is `.ta`, in a course that is not archived. A student
// joins by code alone: the code on a screen names one open session. The
// attendance page and Remove are in `WebRoutes+SessionAttendance.swift`.

import Core
import Elementary
import Fluent
import Foundation
import Vapor

extension WebRoutes {

    /// Start, end and Remove. `userID` is the student a Remove names.
    struct SessionForm: Content {
        var groupID: String?
        var userID: String?
    }

    private struct JoinForm: Content {
        var code: String?
    }

    func registerSessionRoutes(on routes: any RoutesBuilder) {
        routes.post("testsetups", ":testSetupID", "sessions", "start", use: startGroupSession)
        routes.post("testsetups", ":testSetupID", "sessions", "end", use: endGroupSession)
        routes.get("testsetups", ":testSetupID", "sessions", "attendance", use: sessionAttendancePage)
        routes.post("testsetups", ":testSetupID", "sessions", "remove", use: removeFromSession)
        routes.get("join", use: joinSessionPage)
        routes.post("join", use: joinSession)
    }

    @Sendable
    func startGroupSession(req: Request) async throws -> Response {
        let form = try await req.decodeContent(SessionForm.self)
        let (user, assignment, groupID) = try await requireGroupSession(req, groupID: form.groupID, toChange: true)
        let now = Date()
        let session = try await ActivitySessionStore.open(
            assignmentID: assignment.requireID(), groupID: groupID, by: user.id, network: req.clientNetwork,
            now: now, on: req.db)
        // A Start on an open session changes nothing, so it is not audited.
        if session.openedAt == now {
            await recordSessionChange(assignment, session: session, change: "started", on: req)
        }
        return req.redirect(to: presentPath(assignment, groupID: groupID))
    }

    @Sendable
    func endGroupSession(req: Request) async throws -> Response {
        let form = try await req.decodeContent(SessionForm.self)
        let (_, assignment, groupID) = try await requireGroupSession(req, groupID: form.groupID, toChange: true)
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
                code: form.code ?? "", userID: user.requireID(), network: req.clientNetwork, on: req.db)
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
    /// that sessions read. `toChange` false lets a TA read an archived
    /// course's sessions.
    func requireGroupSession(
        _ req: Request, groupID rawGroupID: String?, toChange: Bool
    ) async throws -> (APIUser, APIAssignment, UUID) {
        let user = try req.auth.require(APIUser.self)
        guard let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else { throw Abort(.notFound) }
        if toChange {
            try await requireCourseWriteAccess(caller: user, courseID: setup.courseID, atLeast: .ta, db: req.db)
        } else {
            try await requireCourseRole(caller: user, courseID: setup.courseID, atLeast: .ta, db: req.db)
        }
        guard setup.decodedManifest()?.activity?.runsPerGroup == true,
            let assignment = try await assignmentByTestSetupID(setupID, on: req.db)
        else { throw Abort(.notFound) }
        guard let groupID = rawGroupID.flatMap(UUID.init(uuidString:)),
            let group = try await APICourseGroup.find(groupID, on: req.db),
            group.removedAt == nil,
            try await CourseGroupStore.sets(courseID: setup.courseID, on: req.db).first?.id == group.setID
        else { throw Abort(.notFound) }
        return (user, assignment, groupID)
    }

    /// Audits a start, an end or a removal. `student` names the student a
    /// removal took out.
    func recordSessionChange(
        _ assignment: APIAssignment, session: APIActivitySession, change: String, student: UUID? = nil,
        on req: Request
    ) async {
        var metadata = [
            "assignment": assignment.publicID,
            "group": session.groupID.uuidString,
            "change": change,
        ]
        metadata["student"] = student?.uuidString
        await AuditLogger.record(
            action: .activityGroupSessionChanged,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: metadata,
            courseID: assignment.courseID,
            on: req
        )
    }

    func presentPath(_ assignment: APIAssignment, groupID: UUID) -> String {
        "/testsetups/\(assignment.testSetupID)/leaderboard?present=1&group=\(groupID.uuidString)"
    }
}
