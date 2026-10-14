// APIServer/Models/APIAvatarHatch.swift
//
// One "Hatch a new bird" (Core/AvatarHatch.swift). A user's rows for the
// current term, counted, are the hatches used; the newest row's date is the
// "Hatched …" line on the account page.

import Fluent
import Vapor

final class APIAvatarHatch: Model, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "avatar_hatches"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userID: UUID

    /// `AvatarHatch.termKey(for:)`: "2026-fall".
    @Field(key: "term_key")
    var termKey: String

    /// 1, 2 or 3: which of the term's hatches this is. Unique per user and
    /// term, so the limit holds when two requests race.
    @Field(key: "slot")
    var slot: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(userID: UUID, termKey: String, slot: Int) {
        self.userID = userID
        self.termKey = termKey
        self.slot = slot
    }
}
