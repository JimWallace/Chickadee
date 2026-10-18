// APIServer/Models/APIActivitySessionAttendance.swift
//
// A student who entered a session's join code (docs/lab-groups.md, slice 2).
// Attendance beats membership: the student plays in that session's group,
// whatever group the set gives them. One row per (session, student), whose
// `joinedAt` is the latest join: a join before the session's latest start
// does not count. Rows follow their session and their student on delete.

import Fluent
import Vapor

final class APIActivitySessionAttendance: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "activity_session_attendance"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "session_id")
    var sessionID: UUID

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "joined_at")
    var joinedAt: Date

    init() {}

    init(sessionID: UUID, userID: UUID, joinedAt: Date) {
        self.sessionID = sessionID
        self.userID = userID
        self.joinedAt = joinedAt
    }
}
