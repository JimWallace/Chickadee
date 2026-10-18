// APIServer/Routes/Web/LeaderboardGroupScope.swift
//
// Which lab group's board the leaderboard page shows, for an activity that
// runs once per group (docs/lab-groups.md, slice 3). Staff pick a group and
// land on their own; a student sees the group whose session they last
// joined, else one they ranked in, else the one they are a member of.

import Core
import Fluent
import Foundation
import Vapor

struct LeaderboardGroupScope: Sendable {
    /// The group shown; nil for a student in no group, who sees no board.
    let groupID: UUID?
    let groupName: String?
    /// Every group of the course's set, for the staff picker; empty for a
    /// student, who sees only their own.
    let options: [GroupOption]
    /// True while the shown group's session is open, so the board refreshes.
    let isLive: Bool

    /// `&group=<id>`, for the poll URL, so a refresh shows the same group.
    var groupQuery: String { groupID.map { "&group=\($0.uuidString)" } ?? "" }

    /// The scope for a per-group activity, or nil for any other activity or a
    /// course with no group set.
    static func resolve(
        req: Request, user: APIUser, isStaff: Bool, activity: ClassActivity, setup: APITestSetup,
        assignment: APIAssignment?
    ) async throws -> LeaderboardGroupScope? {
        guard activity.isPerGroup, let assignmentID = assignment?.id,
            let setID = try await CourseGroupStore.sets(courseID: setup.courseID, on: req.db).first?.id
        else { return nil }
        let groups = try await CourseGroupStore.groups(inSet: setID, on: req.db)
        let userID = try user.requireID()
        let shownID: UUID?
        if isStaff {
            let requested = req.query[String.self, at: "group"].flatMap(UUID.init(uuidString:))
            let own = try await CourseGroupStore.groupIDsByUser(inSet: setID, on: req.db)[userID]
            shownID = (groups.first { $0.id == requested } ?? groups.first { $0.id == own } ?? groups.first)?.id
        } else {
            shownID = try await studentGroup(
                userID: userID, setupID: setup.id ?? "", assignmentID: assignmentID, setID: setID, on: req.db)
        }
        var isLive = false
        if let shownID {
            isLive =
                try await ActivitySessionStore.session(assignmentID: assignmentID, groupID: shownID, on: req.db)?
                .isOpen(at: Date()) == true
        }
        return LeaderboardGroupScope(
            groupID: shownID,
            groupName: groups.first { $0.id == shownID }?.name,
            options: isStaff
                ? groups.compactMap { group in group.id.map { GroupOption(id: $0.uuidString, name: group.name) } }
                : [],
            isLive: isLive)
    }

    /// The group a student's board is: the one whose session they last
    /// joined and were not removed from (attendance beats membership), else one they ranked in, else
    /// the one they are a member of.
    private static func studentGroup(
        userID: UUID, setupID: String, assignmentID: UUID, setID: UUID, on db: any Database
    ) async throws -> UUID? {
        let sessions = try await ActivitySessionStore.sessions(assignmentID: assignmentID, on: db)
        if !sessions.isEmpty,
            let latest = try await APIActivitySessionAttendance.query(on: db)
                .filter(\.$userID == userID)
                .filter(\.$sessionID ~~ sessions.compactMap(\.id))
                .filter(\.$removedAt == nil)
                .sort(\.$joinedAt, .descending)
                .first(),
            let joined = sessions.first(where: { $0.id == latest.sessionID })
        {
            return joined.groupID
        }
        if let ranked = try await APIGroupLeaderboardEntry.query(on: db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$userID == userID)
            .sort(\.$reachedAt, .descending)
            .first()?.groupID
        {
            return ranked
        }
        return try await CourseGroupStore.groupIDsByUser(inSet: setID, on: db)[userID]
    }
}
