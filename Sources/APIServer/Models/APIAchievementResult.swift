// APIServer/Models/APIAchievementResult.swift
//
// A computed snapshot of a class-wide achievement's progress for one
// assignment — one row per (testSetupID, achievementID).  Written by the
// periodic `evaluateClassGoalAchievements` sweep and read at grade / display
// time.
//
// `APIResult` rows are immutable, so the class aggregate can't live on them;
// it gets its own table, the same "computed result lives beside the immutable
// runner result" pattern as `APIGradeOverride` and `APIClassAchievement`.

import Fluent
import Vapor

final class APIAchievementResult: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within the evaluation sweep, never
    // across concurrent tasks (one sweep runs at a time).
    static let schema = "achievement_results"

    @ID(key: .id)
    var id: UUID?

    /// The assignment (test setup) this snapshot is scoped to.
    @Field(key: "test_setup_id")
    var testSetupID: String

    /// The `Achievement.id` within that assignment's manifest.
    @Field(key: "achievement_id")
    var achievementID: String

    /// How many enrolled students currently meet the goal's threshold.
    @Field(key: "students_meeting")
    var studentsMeeting: Int

    /// Enrolled-student count used as the denominator (the class size).
    @Field(key: "denominator")
    var denominator: Int

    /// Fraction of the goal reached, `0...1`: the share of the class meeting the
    /// threshold, scaled by the goal's target share.  `1.0` once the target
    /// share (or more) has reached it.  Drives the bonus and the progress bar.
    @Field(key: "progress")
    var progress: Double

    /// UNION goals only: how many distinct suite items the class had covered
    /// when this snapshot was written, within the goal's item scope.  nil for a
    /// grade-counted goal, which unions nothing.
    ///
    /// Stored rather than recomputed because the snapshot freezes at the
    /// deadline and its progress rides into the LEARN push: a frozen row must
    /// be able to say what coverage it froze at.
    @OptionalField(key: "items_covered")
    var itemsCovered: Int?

    /// UNION goals only: how many distinct items the goal asked for — the
    /// condition's authored value, captured alongside the count so the frozen
    /// row is readable without re-decoding the manifest it was graded against.
    @OptionalField(key: "items_required")
    var itemsRequired: Int?

    /// True once the assignment deadline has passed; a locked snapshot is frozen
    /// (the sweep stops recomputing it).
    @Field(key: "locked")
    var locked: Bool

    @Field(key: "evaluated_at")
    var evaluatedAt: Date

    init() {}

    init(
        testSetupID: String,
        achievementID: String,
        studentsMeeting: Int,
        denominator: Int,
        progress: Double,
        locked: Bool,
        evaluatedAt: Date,
        itemsCovered: Int? = nil,
        itemsRequired: Int? = nil
    ) {
        self.testSetupID = testSetupID
        self.achievementID = achievementID
        self.studentsMeeting = studentsMeeting
        self.denominator = denominator
        self.progress = progress
        self.locked = locked
        self.evaluatedAt = evaluatedAt
        self.itemsCovered = itemsCovered
        self.itemsRequired = itemsRequired
    }
}
