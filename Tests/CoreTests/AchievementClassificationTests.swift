// Tests/CoreTests/AchievementClassificationTests.swift
//
// The derived predicates on `Achievement` that decide which grading path an
// achievement takes — `isClassGoal`, `isPerSubmissionBadge`,
// `isAuthorableIndividualBadge`, `usesDynamicSignal`,
// `isSweepEvaluableClassGoal` — plus the `.equals` arm of a condition's
// comparator.
//
// The 2026-08-19 sweep (run 32265903112) reported sixteen survivors across
// these, and the reason is visible in the shape of the tests next door:
// `AchievementTests` builds one achievement of each kind, round-trips it
// through Codable, and asserts the predicate that should hold. Every case
// satisfies every operand, so flipping an `&&` to `||` changes nothing anyone
// checks. Detecting that needs the opposite case — an achievement satisfying
// exactly ONE operand — which is what this file adds.
//
// Getting these wrong is not cosmetic. `isPerSubmissionBadge` and
// `isAuthorableIndividualBadge` partition individual badges into the ones
// evaluated from a submission's run context and the ones an instructor can
// author against grade and test results; `isSweepEvaluableClassGoal` decides
// whether the class-goal sweep can evaluate a goal at all or must skip it. A
// predicate that answers true too often silently routes an achievement into
// machinery that cannot evaluate it.
//
// Every mutation named below was confirmed SURVIVED by
// `Tools/mutation/verify-survivor.py` against that run's record before the test
// was written, and KILLED after.

import Foundation
import Testing

@testable import Core

@Suite struct AchievementClassificationTests {

    private func achievement(
        scope: AchievementScope,
        reward: RewardType,
        conditions: [AchievementCondition] = [],
        match: ConditionMatch = .all
    ) -> Achievement {
        Achievement(
            id: "ach", name: "Ach", scope: scope, conditions: conditions, match: match,
            reward: AchievementReward(type: reward, label: "Ach"))
    }

    private func condition(
        _ signal: AchievementSignal, _ comparator: ConditionComparator = .atLeast, _ value: Double = 1
    ) -> AchievementCondition {
        AchievementCondition(signal: signal, comparator: comparator, value: value)
    }

    // MARK: The comparator

    /// Kills the `RelationalOperatorReplacement` on `compare`'s `.equals` arm
    /// (`lhs == value` → `!=`), which inverts it into "any value but this one".
    @Test func equalsComparatorMatchesTheValueAndNothingElse() {
        let exactly80 = condition(.grade, .equals, 80)
        #expect(exactly80.isSatisfied(by: AchievementSignals(gradePercent: 80)))
        #expect(!exactly80.isSatisfied(by: AchievementSignals(gradePercent: 79)))
        #expect(!exactly80.isSatisfied(by: AchievementSignals(gradePercent: 81)))
    }

    // MARK: usesDynamicSignal

    /// Kills all four mutants on the three-term signal test at L117–118: two
    /// `RelationalOperatorReplacement`s (`!= .attempts`, `!= .executionTimeMs`),
    /// one on `.gradeJumpPercent`, and the `ChangeLogicalConnector` that makes
    /// `.executionTimeMs` require being `.gradeJumpPercent` at the same time.
    ///
    /// Driven off `allCases` rather than a hand-listed set, so a sixth signal
    /// has to be classified here rather than silently defaulting to static —
    /// which is the direction that matters: a new dynamic signal treated as
    /// static makes its badge instructor-authorable, and the authoring UI would
    /// offer a condition the submission-time evaluator never runs.
    @Test(arguments: AchievementSignal.allCases)
    func dynamicSignalsAreExactlyThePerAttemptOnes(signal: AchievementSignal) {
        let dynamic: Set<AchievementSignal> = [.attempts, .executionTimeMs, .gradeJumpPercent]
        let ach = achievement(scope: .individual, reward: .badge, conditions: [condition(signal)])
        #expect(ach.usesDynamicSignal == dynamic.contains(signal))
    }

    @Test func anAchievementWithNoConditionsUsesNoDynamicSignal() {
        #expect(!achievement(scope: .individual, reward: .badge).usesDynamicSignal)
    }

    // MARK: isClassGoal

    /// Kills the `ChangeLogicalConnector` on `scope == .classWide && reward.type
    /// == .points`. Under `||` a class-wide *badge* and an individual *points*
    /// award both read as class goals, and the class-goal sweep would then try
    /// to evaluate a fraction of the class against an achievement that has no
    /// bonus to award.
    @Test func classGoalNeedsClassWideScopeAndAPointsReward() {
        #expect(achievement(scope: .classWide, reward: .points).isClassGoal)
        // Each of these satisfies exactly one operand.
        #expect(!achievement(scope: .classWide, reward: .badge).isClassGoal)
        #expect(!achievement(scope: .individual, reward: .points).isClassGoal)
        #expect(!achievement(scope: .individual, reward: .badge).isClassGoal)
    }

    // MARK: the two individual-badge predicates

    /// Kills both `ChangeLogicalConnector`s on `isPerSubmissionBadge`
    /// (`scope == .individual && reward.type == .badge && usesDynamicSignal`).
    /// Each case below satisfies two of the three operands and fails one, which
    /// is what an `&&`→`||` flip needs in order to show.
    @Test func perSubmissionBadgeNeedsIndividualScopeABadgeAndADynamicSignal() {
        let dynamic = [condition(.attempts)]
        let staticOnly = [condition(.grade)]

        #expect(
            achievement(scope: .individual, reward: .badge, conditions: dynamic)
                .isPerSubmissionBadge)
        #expect(
            !achievement(scope: .classWide, reward: .badge, conditions: dynamic)
                .isPerSubmissionBadge)
        #expect(
            !achievement(scope: .individual, reward: .points, conditions: dynamic)
                .isPerSubmissionBadge)
        #expect(
            !achievement(scope: .individual, reward: .badge, conditions: staticOnly)
                .isPerSubmissionBadge)
    }

    /// Kills all four mutants on `isAuthorableIndividualBadge` — two
    /// `ChangeLogicalConnector`s and two `RelationalOperatorReplacement`s
    /// (`scope != .individual`, `reward.type != .badge`).
    ///
    /// It is the complement of the predicate above on its third operand, so the
    /// pair must never both hold: the same badge cannot be both evaluated from
    /// run context and authorable against grade alone.
    @Test func authorableIndividualBadgeIsTheStaticSignalComplement() {
        let dynamic = [condition(.executionTimeMs)]
        let staticOnly = [condition(.grade)]

        #expect(
            achievement(scope: .individual, reward: .badge, conditions: staticOnly)
                .isAuthorableIndividualBadge)
        #expect(
            !achievement(scope: .individual, reward: .badge, conditions: dynamic)
                .isAuthorableIndividualBadge)
        #expect(
            !achievement(scope: .classWide, reward: .badge, conditions: staticOnly)
                .isAuthorableIndividualBadge)
        #expect(
            !achievement(scope: .individual, reward: .points, conditions: staticOnly)
                .isAuthorableIndividualBadge)

        // The partition itself: never both, for any of the four shapes above.
        for conditions in [dynamic, staticOnly, []] {
            for scope in [AchievementScope.individual, .classWide, .record] {
                for reward in [RewardType.badge, .points, .title] {
                    let a = achievement(scope: scope, reward: reward, conditions: conditions)
                    #expect(!(a.isPerSubmissionBadge && a.isAuthorableIndividualBadge))
                }
            }
        }
    }

    // MARK: isSweepEvaluableClassGoal

    /// Kills the `RelationalOperatorReplacement` on `conditions.count == 1` and
    /// all three mutants on the final clause (`ChangeLogicalConnector`, plus
    /// `!= .grade` and `!= .atLeast`).
    ///
    /// The sweep counts students by their best whole-assignment grade, so it can
    /// evaluate exactly two shapes: no conditions, or a single `grade` /
    /// `atLeast`. Anything richer would be silently mis-evaluated, which is why
    /// answering true too often is the dangerous direction — the `||` mutant
    /// accepts `grade`/`atMost`, and a goal meaning "at most 80%" would then be
    /// counted as if it meant "at least".
    @Test func sweepEvaluableClassGoalAcceptsOnlyNoConditionsOrASingleGradeAtLeast() {
        func goal(_ conditions: [AchievementCondition]) -> Achievement {
            achievement(scope: .classWide, reward: .points, conditions: conditions)
        }

        #expect(goal([]).isSweepEvaluableClassGoal)
        #expect(goal([condition(.grade, .atLeast, 80)]).isSweepEvaluableClassGoal)

        // Right signal, wrong comparator — and vice versa.
        #expect(!goal([condition(.grade, .atMost, 80)]).isSweepEvaluableClassGoal)
        #expect(!goal([condition(.grade, .equals, 80)]).isSweepEvaluableClassGoal)
        #expect(!goal([condition(.attempts, .atLeast, 1)]).isSweepEvaluableClassGoal)

        // More than one condition, even when the first is the evaluable shape.
        #expect(
            !goal([condition(.grade, .atLeast, 80), condition(.attempts, .atMost, 2)])
                .isSweepEvaluableClassGoal)

        // Not a class goal at all.
        #expect(
            !achievement(scope: .individual, reward: .badge, conditions: [])
                .isSweepEvaluableClassGoal)
    }
}
