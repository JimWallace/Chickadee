// APIServer/Helpers/BuiltInAchievements.swift
//
// The canonical definition of Chickadee's built-in awards, expressed in the
// composable `Achievement` model.  These used to live as hardcoded
// `AchievementBadge` literals + a string switch (the "legacy" badges); folding
// them in here makes the `Achievement` model the single registry for every
// award — built-in or instructor-authored — and the display badge is derived
// from these definitions (`AchievementBadge(from:)`).
//
// Each award is now just a (scope, conditions, reward) triple — the same shape
// an instructor authors.  Evaluation walks the conditions (`Achievement
// .isSatisfied(by:)`); this registry owns only each award's identity — id,
// caption, tooltip, conditions, and (for records) ranking dimension — so there
// is exactly one place that defines what "Ace" or "Trailblazer" is.

import Core

enum BuiltInAchievements {

    /// A grade-percent floor condition (`grade ≥ pct`).
    private static func grade(_ pct: Double) -> AchievementCondition {
        AchievementCondition(signal: .grade, comparator: .atLeast, value: pct)
    }

    // MARK: Per-submission (individual) awards

    /// 100% on the very first attempt.
    static let ace = Achievement(
        id: "first_try_perfect",
        name: "Ace",
        detail: "Scored 100% on your very first submission — no warm-up needed.",
        scope: .individual,
        conditions: [
            grade(100),
            AchievementCondition(signal: .attempts, comparator: .atMost, value: 1),
        ],
        reward: AchievementReward(type: .badge, label: "Ace"))

    /// Jumped ≥50 percentage points in one submission.
    static let rally = Achievement(
        id: "comeback_kid",
        name: "Rally",
        detail: "Jumped 50 or more percentage points in a single submission.",
        scope: .individual,
        conditions: [
            AchievementCondition(signal: .gradeJumpPercent, comparator: .atLeast, value: 50)
        ],
        reward: AchievementReward(type: .badge, label: "Rally"))

    /// 100% after ≥5 attempts.
    static let tenacious = Achievement(
        id: "tenacious",
        name: "Tenacious",
        detail: "Reached 100% after 5 or more attempts — persistence pays off.",
        scope: .individual,
        conditions: [
            grade(100),
            AchievementCondition(signal: .attempts, comparator: .atLeast, value: 5),
        ],
        reward: AchievementReward(type: .badge, label: "Tenacious"))

    /// 100% with total execution under 2 s.
    static let swift = Achievement(
        id: "speed_demon",
        name: "Swift",
        detail: "Scored 100% with every test completing in under 2 seconds total.",
        scope: .individual,
        conditions: [
            grade(100),
            AchievementCondition(signal: .executionTimeMs, comparator: .atMost, value: 2000),
        ],
        reward: AchievementReward(type: .badge, label: "Swift"))

    /// In display order — `forSubmission` walks this list.
    static let perSubmission = [ace, rally, tenacious, swift]

    // MARK: Competitive records (one holder per assignment)

    static let pathfinder = Achievement(
        id: "pathfinder",
        name: "Pathfinder",
        detail: "Submitted before anyone else in the class.",
        scope: .record,
        reward: AchievementReward(type: .title, label: "Pathfinder"),
        recordDimension: .firstToSubmit)

    static let trailblazer = Achievement(
        id: "trailblazer",
        name: "Trailblazer",
        detail: "First student in the class to reach 100% on this assignment.",
        scope: .record,
        reward: AchievementReward(type: .title, label: "Trailblazer"),
        recordDimension: .firstToSolve)

    static let speedChampion = Achievement(
        id: "speed_champion",
        name: "Fastest",
        detail: "Holds the class record for fastest 100% execution time.",
        scope: .record,
        reward: AchievementReward(type: .title, label: "Fastest"),
        recordDimension: .fastest)

    static let minimalist = Achievement(
        id: "minimalist",
        name: "Minimalist",
        detail: "Reached 100% in fewer attempts than any other student in the class.",
        scope: .record,
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

    /// The set of built-in award ids this assignment has disabled (empty when
    /// the manifest can't be decoded or disables nothing — the common case).
    static func disabled(in setup: APITestSetup) -> Set<String> {
        Set(setup.decodedManifest()?.disabledBuiltInAwardIDs ?? [])
    }

    /// Per-setup achievement data for the multi-assignment pages: disabled
    /// built-in ids, the authored per-submission list (nil = registry
    /// fallback), and the full authored achievements (so manifest-authored
    /// class records resolve at display time, audit A6).  One setups query
    /// covers all three maps — this replaced the separate `disabledBySetup` /
    /// `manifestPerSubmissionBySetup` fetches that each queried the same rows.
    struct SetupAchievementData {
        var disabled: Set<String> = []
        var perSubmission: [Achievement]?
        var achievements: [Achievement] = []
    }

    /// Batch `[setupID: SetupAchievementData]` over already-loaded setup rows;
    /// setups whose manifest can't be decoded are absent (callers treat that
    /// as "registry defaults, nothing disabled").  Takes the rows rather than
    /// querying: the caller has already fetched the setups it is rendering,
    /// and re-selecting them — manifest blobs included — doubled the
    /// dashboard's setup reads on every render (#1382 item 2).
    static func achievementDataBySetup(
        setups: [APITestSetup]
    ) -> [String: SetupAchievementData] {
        var map: [String: SetupAchievementData] = [:]
        for setup in setups {
            guard let id = setup.id, let props = setup.decodedManifest() else { continue }
            map[id] = SetupAchievementData(
                disabled: Set(props.disabledBuiltInAwardIDs),
                perSubmission: manifestPerSubmission(props: props),
                achievements: props.achievements)
        }
        return map
    }

    /// The manifest's authored per-submission achievements, or nil to fall back
    /// to the registry.  `forSubmission` uses this so seeded / edited
    /// per-submission badges take effect once a manifest carries any.
    /// A **curated** manifest (`builtInAchievementsSeeded`) is authoritative
    /// even when the filtered list is empty — the instructor removed every
    /// per-submission badge, so return [] rather than nil (audit A5: an empty
    /// curated list used to silently resurrect the registry defaults).
    static func manifestPerSubmission(in setup: APITestSetup?) -> [Achievement]? {
        manifestPerSubmission(props: setup?.decodedManifest())
    }

    /// `manifestPerSubmission(in:)` over an already-decoded manifest.
    static func manifestPerSubmission(props: TestProperties?) -> [Achievement]? {
        guard let props else { return nil }
        let perSub = props.achievements.filter { $0.isPerSubmissionBadge }
        if !perSub.isEmpty { return perSub }
        return props.builtInAchievementsSeeded ? [] : nil
    }

    /// The class records to award for a setup: the manifest's authored
    /// `classRecord` achievements (or the registry default when none), minus
    /// any the instructor disabled.  Callers award each by its `recordDimension`.
    /// Like `manifestPerSubmission`, a curated manifest with no records means
    /// the instructor removed them all — award none, don't fall back (audit A5).
    static func classRecordsForAward(
        in setup: APITestSetup?, disabled: Set<String>
    ) -> [Achievement] {
        let props = setup?.decodedManifest()
        let manifest = (props?.achievements ?? []).filter { $0.isClassRecord }
        let source: [Achievement]
        if !manifest.isEmpty {
            source = manifest
        } else if props?.builtInAchievementsSeeded == true {
            source = []
        } else {
            source = classRecords
        }
        return source.filter { !disabled.contains($0.id) }
    }
}
