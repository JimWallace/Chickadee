// APIServer/Models/APIClassAchievement.swift
//
// Tracks class-wide achievement badges — one winner (or current record holder)
// per achievement per test setup.
//
// Immutable badges (pathfinder, trailblazer): awarded once, never updated.
// Record-holder badges (speed_champion, minimalist): userID/submissionID updated
// when a student beats the current record.

import Fluent
import Vapor

final class APIClassAchievement: Model, Content, @unchecked Sendable {
    static let schema = "class_achievements"

    @ID(key: .id)
    var id: UUID?

    /// Which assignment this badge is scoped to.
    @Field(key: "test_setup_id")
    var testSetupID: String

    /// Badge identifier: "pathfinder" | "trailblazer" | "speed_champion" | "minimalist"
    @Field(key: "achievement_id")
    var achievementID: String

    /// The student currently holding this badge.
    @Field(key: "user_id")
    var userID: UUID

    /// The specific submission that earned (or currently holds) this badge.
    @Field(key: "submission_id")
    var submissionID: String

    /// For record-holder badges: the metric that can be beaten.
    /// speed_champion → executionTimeMs (lower is better)
    /// minimalist     → attemptNumber   (lower is better)
    @OptionalField(key: "metric_value")
    var metricValue: Double?

    @Timestamp(key: "awarded_at", on: .create)
    var awardedAt: Date?

    init() {}

    init(
        testSetupID: String,
        achievementID: String,
        userID: UUID,
        submissionID: String,
        metricValue: Double? = nil
    ) {
        self.testSetupID = testSetupID
        self.achievementID = achievementID
        self.userID = userID
        self.submissionID = submissionID
        self.metricValue = metricValue
    }
}
