// APIServer/Models/APIWardrobeUnlock.swift
//
// One wardrobe item a student has earned (Core/WardrobeItem.swift, #2592). A
// row is sticky: it is never removed when a later regrade changes the result
// that earned it, and it goes with the user.

import Core
import Fluent
import Vapor

final class APIWardrobeUnlock: Model, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "wardrobe_unlocks"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userID: UUID

    /// `WardrobeItem.rawValue`: "expression.chirp". Unique per user, so two
    /// requests that grant the same item at once store it once.
    @Field(key: "item")
    var item: String

    @Timestamp(key: "unlocked_at", on: .create)
    var unlockedAt: Date?

    /// What granted the item: `achievement:<level>:<owner>:<id>` for an item
    /// an achievement granted (docs/achievement-rewards.md, S2); nil for an
    /// item a built-in rule earned or a student found.
    @OptionalField(key: "source")
    var source: String?

    /// The name of the achievement that granted the item, for the account
    /// page's "how you earned it"; nil for a rule item or a found one.
    @OptionalField(key: "label")
    var label: String?

    init() {}

    init(userID: UUID, item: WardrobeItem, source: String? = nil, label: String? = nil) {
        self.userID = userID
        self.item = item.rawValue
        self.source = source
        self.label = label
    }
}
