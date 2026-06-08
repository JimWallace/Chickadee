// APIServer/Helpers/BuiltInAchievements.swift
//
// The canonical definition of Chickadee's built-in awards, expressed in the
// unified `Achievement` model.  These used to live as hardcoded
// `AchievementBadge` literals + a string switch (the "legacy" badges); folding
// them in here makes the `Achievement` model the single registry for every
// award — built-in or instructor-authored — and the display badge is derived
// from these definitions (`AchievementBadge(from:)`).
//
// Behaviour is unchanged: the per-submission award *conditions* still live in
// `AchievementBadge.forSubmission` (keyed by kind), and the class-record award
// logic still lives in `ClassAchievements`.  This registry owns only each
// award's identity — id, caption, tooltip, kind, and (for records) ranking
// dimension — so there is exactly one place that defines what "Ace" or
// "Trailblazer" is.

import Core

enum BuiltInAchievements {

    // MARK: Per-submission (individual) awards

    /// 100% on the very first attempt.
    static let ace = Achievement(
        id: "first_try_perfect",
        name: "Ace",
        detail: "Scored 100% on your very first submission — no warm-up needed.",
        kind: .firstTryPerfect,
        scope: .individual,
        reward: AchievementReward(type: .badge, label: "Ace"))

    /// Jumped ≥50 percentage points in one submission.
    static let rally = Achievement(
        id: "comeback_kid",
        name: "Rally",
        detail: "Jumped 50 or more percentage points in a single submission.",
        kind: .comeback,
        scope: .individual,
        reward: AchievementReward(type: .badge, label: "Rally"))

    /// 100% after ≥5 attempts.
    static let tenacious = Achievement(
        id: "tenacious",
        name: "Tenacious",
        detail: "Reached 100% after 5 or more attempts — persistence pays off.",
        kind: .persistence,
        scope: .individual,
        reward: AchievementReward(type: .badge, label: "Tenacious"))

    /// 100% with total execution under 2 s.
    static let swift = Achievement(
        id: "speed_demon",
        name: "Swift",
        detail: "Scored 100% with every test completing in under 2 seconds total.",
        kind: .speedRun,
        scope: .individual,
        reward: AchievementReward(type: .badge, label: "Swift"))

    /// In display order — `forSubmission` walks this list.
    static let perSubmission = [ace, rally, tenacious, swift]

    // MARK: Class-wide (competitive) records

    static let pathfinder = Achievement(
        id: "pathfinder",
        name: "Pathfinder",
        detail: "Submitted before anyone else in the class.",
        kind: .classRecord,
        scope: .classWide,
        reward: AchievementReward(type: .title, label: "Pathfinder"),
        recordDimension: .firstToSolve)

    static let trailblazer = Achievement(
        id: "trailblazer",
        name: "Trailblazer",
        detail: "First student in the class to reach 100% on this assignment.",
        kind: .classRecord,
        scope: .classWide,
        reward: AchievementReward(type: .title, label: "Trailblazer"),
        recordDimension: .firstToSolve)

    static let speedChampion = Achievement(
        id: "speed_champion",
        name: "Fastest",
        detail: "Holds the class record for fastest 100% execution time.",
        kind: .classRecord,
        scope: .classWide,
        reward: AchievementReward(type: .title, label: "Fastest"),
        recordDimension: .fastest)

    static let minimalist = Achievement(
        id: "minimalist",
        name: "Minimalist",
        detail: "Reached 100% in fewer attempts than any other student in the class.",
        kind: .classRecord,
        scope: .classWide,
        reward: AchievementReward(type: .title, label: "Minimalist"),
        recordDimension: .shortest)

    /// The class records, keyed by `APIClassAchievement.achievementID`.
    static let classRecords = [pathfinder, trailblazer, speedChampion, minimalist]

    /// Every built-in award.
    static let all = perSubmission + classRecords

    /// The built-in award with this id, if any.
    static func byID(_ id: String) -> Achievement? {
        all.first { $0.id == id }
    }
}
