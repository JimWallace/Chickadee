// Tests/CoreTests/CoverageClassGoalClassificationTests.swift
//
// `isCoverageClassGoal` needs BOTH a class goal and a `classCoverage`
// condition. The API-level test (APITests/ClassCoverageGoalTests.swift) only
// checks the positive case, and the weekly mutation sweep skips APITests.

import Core
import Testing

@Suite struct CoverageClassGoalClassificationTests {

    private func achievement(
        scope: AchievementScope, signal: AchievementSignal, rewardType: RewardType = .points
    ) -> Achievement {
        Achievement(
            id: "a", name: "A", scope: scope,
            conditions: [AchievementCondition(signal: signal, comparator: .atLeast, value: 80)],
            reward: AchievementReward(type: rewardType, label: "A", points: 5),
            classFraction: 0.6)
    }

    @Test func aClassGoalReadingClassCoverageIsACoverageGoal() {
        let goal = achievement(scope: .classWide, signal: .classCoverage)
        #expect(goal.isCoverageClassGoal)
        #expect(goal.coveragePercentRequirement == 80)
    }

    @Test func aClassGoalReadingAnotherSignalIsNotACoverageGoal() {
        let goal = achievement(scope: .classWide, signal: .grade)
        #expect(goal.isClassGoal)
        #expect(!goal.isCoverageClassGoal)
        #expect(goal.coveragePercentRequirement == nil)
    }

    @Test func anIndividualAchievementReadingClassCoverageIsNotACoverageGoal() {
        let badge = achievement(scope: .individual, signal: .classCoverage, rewardType: .badge)
        #expect(!badge.isClassGoal)
        #expect(!badge.isCoverageClassGoal)
        #expect(badge.coveragePercentRequirement == nil)
    }
}
