// APIServer/Models/APIActivitySessionAttendance.swift
//
// A student who entered a session's join code (docs/lab-groups.md, slice 2).
// Only a student who joined plays: the student plays in that session's group,
// whatever group the set gives them. One row per (session, student), whose
// `joinedAt` is the latest join: a join before the session's latest start
// does not count. Course staff can remove a student who is not in the room.
// Rows follow their session and their student on delete.

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

    /// When course staff removed the student from the session. A removed
    /// student cannot join that run of the session again.
    @OptionalField(key: "removed_at")
    var removedAt: Date?

    /// True when this student's join placed them in the session's group
    /// (they were in no group of a manual set). Remove undoes that placement.
    @Field(key: "placed_in_group")
    var placedInGroup: Bool

    /// The network of the latest join (`ClientNetwork.prefix`), never the
    /// full address. Nil when unknown.
    @OptionalField(key: "join_network")
    var joinNetwork: String?

    init() {}

    init(sessionID: UUID, userID: UUID, joinedAt: Date) {
        self.sessionID = sessionID
        self.userID = userID
        self.joinedAt = joinedAt
        self.placedInGroup = false
    }

    /// Whether this row puts its student in the current run of `session`:
    /// a join since the session's latest start, not removed since.
    func counts(in session: APIActivitySession) -> Bool {
        sessionID == session.id && joinedAt >= session.openedAt && removedAt == nil
    }
}
