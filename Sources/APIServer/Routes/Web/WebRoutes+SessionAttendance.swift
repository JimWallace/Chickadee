// APIServer/Routes/Web/WebRoutes+SessionAttendance.swift
//
// Who joined a lab group's session, and Remove (docs/lab-groups.md,
// "Presence"). Presence is best effort: staff see the list and take out a
// student who is not in the room. Course staff only, `.ta` and up; Remove is
// refused in an archived course, as every session change is.

import Core
import Elementary
import Fluent
import Foundation
import Vapor

extension WebRoutes {

    @Sendable
    func sessionAttendancePage(req: Request) async throws -> Response {
        let (user, assignment, groupID) = try await requireGroupSession(
            req, groupID: req.query[String.self, at: "group"], toChange: false)
        guard let group = try await APICourseGroup.find(groupID, on: req.db) else { throw Abort(.notFound) }
        let session = try await ActivitySessionStore.session(
            assignmentID: assignment.requireID(), groupID: groupID, on: req.db)
        let rows = try await attendeeRows(of: session, on: req.db)
        let canRemove =
            (try? await requireCourseWriteAccess(
                caller: user, courseID: assignment.courseID, atLeast: .ta, db: req.db)) != nil
        let removed = req.query[String.self, at: "removed"] != nil
        return try await HTMLResponse {
            SessionAttendancePage(
                page: PageRequestContext(request: req),
                flash: FlashMessages(success: removed ? "Student removed." : nil),
                assignmentTitle: assignment.title, groupName: group.name, testSetupID: assignment.testSetupID,
                groupID: groupID.uuidString, isOpen: session?.isOpen(at: Date()) == true, canRemove: canRemove,
                rows: rows)
        }.encodeResponse(for: req)
    }

    @Sendable
    func removeFromSession(req: Request) async throws -> Response {
        let form = try await req.decodeContent(SessionForm.self)
        let (_, assignment, groupID) = try await requireGroupSession(req, groupID: form.groupID, toChange: true)
        // Only a student in the open session's current run can be removed;
        // anything else changes nothing and is not audited.
        guard let studentID = form.userID.flatMap(UUID.init(uuidString:)),
            let session = try await ActivitySessionStore.session(
                assignmentID: assignment.requireID(), groupID: groupID, on: req.db),
            session.isOpen(at: Date()),
            try await ActivitySessionStore.remove(userID: studentID, from: session, on: req.db)
        else { throw Abort(.notFound) }
        await recordSessionChange(assignment, session: session, change: "removed", student: studentID, on: req)
        return req.redirect(
            to: "/testsetups/\(assignment.testSetupID)/sessions/attendance?group=\(groupID.uuidString)"
                + "&removed=1")
    }

    /// The current run's joins, with each student's name and username, and
    /// whether the join came from another network than the room
    /// (`SessionNetworkCheck`).
    private func attendeeRows(
        of session: APIActivitySession?, on db: any Database
    ) async throws
        -> [SessionAttendeeRow]
    {
        guard let session else { return [] }
        let attendance = try await ActivitySessionStore.attendance(of: session, on: db)
        guard !attendance.isEmpty else { return [] }
        let users = try await APIUser.query(on: db).filter(\.$id ~~ attendance.map(\.userID)).all()
        let userByID = Dictionary(users.compactMap { u in u.id.map { ($0, u) } }, uniquingKeysWith: { a, _ in a })
        let formatter = waterlooDateTimeFormatter()
        let room = SessionNetworkCheck.roomNetworks(
            presenter: session.presenterNetwork, joins: attendance.filter { $0.removedAt == nil }.map(\.joinNetwork))
        return attendance.compactMap { row in
            guard let user = userByID[row.userID] else { return nil }
            return SessionAttendeeRow(
                userID: row.userID.uuidString, name: user.displayName ?? user.username, username: user.username,
                joinedAtText: formatter.string(from: row.joinedAt), isRemoved: row.removedAt != nil,
                // A removed student needs no second look.
                isOtherNetwork: row.removedAt == nil && SessionNetworkCheck.isOtherNetwork(row.joinNetwork, room: room))
        }
    }
}
