// APIServer/Routes/Web/GroupSessionPanel.swift
//
// What the present page shows for a per-group activity (docs/lab-groups.md,
// slice 2): the group the projector is for, its session's state, and, while
// the session is open, the join code, how long it shows and how many joined.

import Core
import Fluent
import Foundation
import Vapor

struct GroupSessionPanel: Sendable {
    let testSetupID: String
    /// Every group of the course's set, for the presenter's picker.
    let groups: [GroupOption]
    let selectedGroupID: String
    let groupName: String
    /// True while the selected group's session is open.
    let isOpen: Bool
    /// True once the selected group's session was ever started.
    let hasStarted: Bool
    /// The code to project; nil unless the session is open.
    let joinCode: String?
    /// Whole seconds until the code changes.
    let secondsLeft: Int
    /// Students in the session's current run.
    let joinedCount: Int
    /// Where students type the code, as the room reads it: "host/join".
    let joinAddress: String

    var boardURL: String { "/testsetups/\(testSetupID)/leaderboard" }
    /// The join code box's own refresh.
    var joinPollURL: String { "\(boardURL)?present=1&fragment=join&group=\(selectedGroupID)" }
    var attendanceURL: String { "/testsetups/\(testSetupID)/sessions/attendance?group=\(selectedGroupID)" }

    /// The panel for a per-group activity, or nil for any other activity or
    /// a course with no groups. The group is `?group=` when it names one of
    /// the set's groups, else the presenter's own group, else the first.
    static func make(
        req: Request, user: APIUser, activity: ClassActivity, assignment: APIAssignment?, courseID: UUID
    ) async throws -> GroupSessionPanel? {
        guard activity.runsPerGroup, let assignmentID = assignment?.id,
            let set = try await CourseGroupStore.sets(courseID: courseID, on: req.db).first,
            let setID = set.id
        else { return nil }
        let groups = try await CourseGroupStore.groups(inSet: setID, on: req.db)
        let requested = req.query[String.self, at: "group"].flatMap(UUID.init(uuidString:))
        let own = try await CourseGroupStore.groupIDsByUser(inSet: setID, on: req.db)[user.requireID()]
        guard
            let selected = groups.first(where: { $0.id == requested }) ?? groups.first(where: { $0.id == own })
                ?? groups.first,
            let groupID = selected.id
        else { return nil }
        let session = try await ActivitySessionStore.session(
            assignmentID: assignmentID, groupID: groupID, on: req.db)
        let now = Date()
        let openSession = session.flatMap { $0.isOpen(at: now) ? $0 : nil }
        var joinedCount = 0
        if let openSession {
            // Only staff reach the present page, so this request is the
            // presenter's screen.
            try await ActivitySessionStore.notePresenterNetwork(req.clientNetwork, for: openSession, on: req.db)
            joinedCount = try await ActivitySessionStore.joinedCount(of: openSession, on: req.db)
        }
        return GroupSessionPanel(
            testSetupID: assignment?.testSetupID ?? "",
            groups: groups.compactMap { group in group.id.map { GroupOption(id: $0.uuidString, name: group.name) } },
            selectedGroupID: groupID.uuidString, groupName: selected.name, isOpen: openSession != nil,
            hasStarted: session != nil,
            joinCode: openSession.map { ActivitySessionCode.code(secret: $0.codeSecret, at: now) },
            secondsLeft: ActivitySessionCode.secondsLeft(at: now),
            joinedCount: joinedCount,
            joinAddress: joinAddress(req))
    }

    /// "chickadee.example.ca/join": the configured public host, else the
    /// host the presenter reached.
    private static func joinAddress(_ req: Request) -> String {
        let host =
            req.application.securityConfiguration.publicBaseURL?.host
            ?? req.headers.first(name: .host)
        return host.map { "\($0)/join" } ?? "/join"
    }
}
