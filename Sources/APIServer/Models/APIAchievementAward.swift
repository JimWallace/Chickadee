// APIServer/Models/APIAchievementAward.swift
//
// One achievement a student has earned (docs/achievement-rewards.md,
// decision 2). A row is sticky: a later regrade that lowers the result that
// earned it does not remove it. The submission page still computes its
// badges from its own run, so the page says what that run earned and the
// ledger says what the student has earned.

import Core
import Fluent
import Vapor

final class APIAchievementAward: Model, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "achievement_awards"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userID: UUID

    /// `AchievementLevel.rawValue`: where the definition lives.
    @Field(key: "level")
    var level: String

    /// The test setup ID at the assignment level. Required, because a unique
    /// index treats two NULLs as different values, so a NULL owner would let
    /// one award be stored twice.
    @Field(key: "owner_id")
    var ownerID: String

    /// `Achievement.id` within its owner.
    @Field(key: "achievement_id")
    var achievementID: String

    /// The submission that earned it, when one did.
    @OptionalField(key: "submission_id")
    var submissionID: String?

    /// The badge caption when it was earned, so the record still reads after
    /// the definition changes or goes away.
    @Field(key: "label")
    var label: String

    /// The badge tooltip when it was earned.
    @OptionalField(key: "detail")
    var detail: String?

    @Timestamp(key: "earned_at", on: .create)
    var earnedAt: Date?

    init() {}

    init(
        userID: UUID, level: AchievementLevel, ownerID: String, achievementID: String,
        submissionID: String?, label: String, detail: String?
    ) {
        self.userID = userID
        self.level = level.rawValue
        self.ownerID = ownerID
        self.achievementID = achievementID
        self.submissionID = submissionID
        self.label = label
        self.detail = detail
    }

    /// The typed level. An unknown stored value reads as nil.
    var achievementLevel: AchievementLevel? { AchievementLevel(rawValue: level) }
}
