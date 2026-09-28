// Tests/CoreTests/StandingSignalTests.swift
//
// The two standings signals (docs/class-activities.md, slice 4): a
// student's place in a round robin and the matches their latest submission
// won. They are evaluated from loaded standings, unmet where none are
// loaded, dynamic (a classmate's submission moves them), and never a class
// goal the sweep would evaluate.

import Foundation
import Testing

@testable import Core

@Suite struct StandingSignalTests {

    private func condition(
        _ signal: AchievementSignal, _ comparator: ConditionComparator, _ value: Double
    ) -> AchievementCondition {
        AchievementCondition(signal: signal, comparator: comparator, value: value)
    }

    @Test func aStandingConditionReadsTheLoadedStandings() {
        let top = condition(.standing, .atMost, 3)
        #expect(top.isSatisfied(by: AchievementSignals(gradePercent: 0, standing: 1)))
        #expect(top.isSatisfied(by: AchievementSignals(gradePercent: 0, standing: 3)))
        #expect(!top.isSatisfied(by: AchievementSignals(gradePercent: 0, standing: 4)))
        let wins = condition(.matchesWon, .atLeast, 5)
        #expect(wins.isSatisfied(by: AchievementSignals(gradePercent: 0, matchesWon: 5)))
        #expect(!wins.isSatisfied(by: AchievementSignals(gradePercent: 0, matchesWon: 4)))
    }

    /// Where no standings are loaded — every page of an ordinary
    /// assignment — the condition is unmet, never satisfied by a default.
    @Test func aStandingConditionIsUnmetWithoutStandings() {
        #expect(!condition(.standing, .atMost, 100).isSatisfied(by: AchievementSignals(gradePercent: 0)))
        #expect(!condition(.matchesWon, .atLeast, 0).isSatisfied(by: AchievementSignals(gradePercent: 0)))
    }

    /// The badge is instructor-authorable, classified static like `grade`:
    /// the submission page evaluates it with the standings it loads.
    @Test func aStandingBadgeIsAuthorable() {
        let badge = Achievement(
            id: "podium", name: "Podium", scope: .individual,
            conditions: [condition(.standing, .atMost, 3)],
            reward: AchievementReward(type: .badge, label: "Podium"))
        #expect(!badge.usesDynamicSignal)
        #expect(badge.isAuthorableIndividualBadge)
        #expect(AchievementSignal.standing.readsTheStandings)
        #expect(AchievementSignal.matchesWon.readsTheStandings)
        #expect(!AchievementSignal.grade.readsTheStandings)
        #expect(!AchievementSignal.standing.readsTheWholeClass)
    }

    /// A class goal cannot carry a standings signal: the sweep evaluates
    /// exactly three shapes, and the save refuses everything else.
    @Test func aStandingsClassGoalIsNotSweepEvaluable() {
        for signal in [AchievementSignal.standing, .matchesWon] {
            let goal = Achievement(
                id: "g", name: "G", scope: .classWide,
                conditions: [condition(signal, .atLeast, 1)],
                reward: AchievementReward(type: .points, label: "G", points: 1),
                classFraction: 0.5)
            #expect(!goal.isSweepEvaluableClassGoal)
        }
    }

    @Test func theSignalsRoundTripByRawValue() throws {
        let decoded = try JSONDecoder().decode(
            [AchievementSignal].self, from: Data(#"["standing","matchesWon"]"#.utf8))
        #expect(decoded == [.standing, .matchesWon])
    }
}
