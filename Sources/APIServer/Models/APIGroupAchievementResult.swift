// APIServer/Models/APIGroupAchievementResult.swift
//
// One lab group's snapshot of a class goal (docs/lab-groups.md, slice 5): the
// per-group twin of `APIAchievementResult`, for an activity that runs once per
// lab group. Each lab's goal is counted from the students whose lab it is,
// and each of them earns their own lab's bonus. One row per (test setup,
// group, achievement). A twin table, because `achievement_results` is unique
// on (test setup, achievement) and SQLite cannot drop that key.

import Fluent
import Foundation

final class APIGroupAchievementResult: Model, @unchecked Sendable {
    // @unchecked Sendable: mutated only within the evaluation sweep.
    static let schema = "group_achievement_results"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "test_setup_id")
    var testSetupID: String

    /// The lab group whose goal this is.
    @Field(key: "group_id")
    var groupID: UUID

    @Field(key: "achievement_id")
    var achievementID: String

    @Field(key: "students_meeting")
    var studentsMeeting: Int

    /// The students whose lab this is (`LabGoalGroups`).
    @Field(key: "denominator")
    var denominator: Int

    @Field(key: "progress")
    var progress: Double

    @OptionalField(key: "items_covered")
    var itemsCovered: Int?

    @OptionalField(key: "items_required")
    var itemsRequired: Int?

    @OptionalField(key: "coverage_percent")
    var coveragePercent: Double?

    @OptionalField(key: "coverage_required")
    var coverageRequired: Double?

    @Field(key: "locked")
    var locked: Bool

    @Field(key: "evaluated_at")
    var evaluatedAt: Date

    init() {}

    init(testSetupID: String, groupID: UUID, achievementID: String) {
        self.testSetupID = testSetupID
        self.groupID = groupID
        self.achievementID = achievementID
        self.studentsMeeting = 0
        self.denominator = 0
        self.progress = 0
        self.locked = false
        self.evaluatedAt = Date()
    }
}
