// APIServer/Models/APICourseGroupMembership.swift
//
// One person in one group (docs/lab-groups.md). The row carries its set as
// well as its group, so the database itself keeps a person in at most one
// group per set: the unique key is (set, user). Rows follow their group, their
// set and their user on delete.

import Fluent
import Vapor

final class APICourseGroupMembership: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "course_group_memberships"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "set_id")
    var setID: UUID

    @Field(key: "group_id")
    var groupID: UUID

    @Field(key: "user_id")
    var userID: UUID

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, setID: UUID, groupID: UUID, userID: UUID) {
        self.id = id
        self.setID = setID
        self.groupID = groupID
        self.userID = userID
    }
}
