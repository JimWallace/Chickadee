// APIServer/Models/APICourseGroup.swift
//
// One group in a group set, for example "Lab 103" (docs/lab-groups.md). A
// removed group keeps its row, so a later ranking or schedule row that names
// it still resolves; only its memberships go. Rows follow their set on delete.

import Fluent
import Vapor

final class APICourseGroup: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "course_groups"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "set_id")
    var setID: UUID

    @Field(key: "name")
    var name: String

    /// The D2L group or section a synced group mirrors. Nil for a manual group.
    @OptionalField(key: "external_id")
    var externalID: String?

    /// The display order inside the set.
    @Field(key: "sort_order")
    var sortOrder: Int

    /// When the group was removed. Nil while it is in use.
    @OptionalField(key: "removed_at")
    var removedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, setID: UUID, name: String, sortOrder: Int, externalID: String? = nil) {
        self.id = id
        self.setID = setID
        self.name = name
        self.sortOrder = sortOrder
        self.externalID = externalID
    }
}
