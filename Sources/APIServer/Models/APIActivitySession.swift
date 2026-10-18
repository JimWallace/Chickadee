// APIServer/Models/APIActivitySession.swift
//
// One lab group running one per-group class activity (docs/lab-groups.md,
// slice 2). The session is the activity's clock for that group: course staff
// start it on the present page when the room is ready and end it when the lab
// ends. A reopen keeps the row and draws a new join code. One row per
// (assignment, group), and a join code names one row.

import Fluent
import Vapor

final class APIActivitySession: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "activity_sessions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "assignment_id")
    var assignmentID: UUID

    @Field(key: "group_id")
    var groupID: UUID

    /// Five characters from `ActivitySessionStore.codeAlphabet`, shown on the
    /// projector and typed on `/join`.
    @Field(key: "join_code")
    var joinCode: String

    @Field(key: "opened_at")
    var openedAt: Date

    /// When staff ended the session. Nil while it is open.
    @OptionalField(key: "closed_at")
    var closedAt: Date?

    /// Who last started it. Nil once that account is deleted.
    @OptionalField(key: "opened_by")
    var openedBy: UUID?

    init() {}

    init(assignmentID: UUID, groupID: UUID, joinCode: String, openedAt: Date, openedBy: UUID?) {
        self.assignmentID = assignmentID
        self.groupID = groupID
        self.joinCode = joinCode
        self.openedAt = openedAt
        self.openedBy = openedBy
    }

    /// True when a submission at `now` falls inside the session. Half-open,
    /// as the live-session window is: the closing instant is outside.
    func isOpen(at now: Date) -> Bool {
        openedAt <= now && (closedAt.map { now < $0 } ?? true)
    }
}
