// Tests/CoreTests/ClassActivityIsPerGroupTests.swift
//
// The one rule for whether an activity behaves per lab group
// (docs/lab-groups.md, slices 3a to 3c): the flag, and a kind whose ranking
// is per group. A flag stored on any other kind reads as course-wide.

import Testing

@testable import Core

@Suite struct ClassActivityIsPerGroupTests {

    @Test(arguments: ActivityKind.allCases)
    func onlyAKindThatCanRunPerGroupIsPerGroup(kind: ActivityKind) {
        let flagged = ClassActivity(kind: kind, runsPerGroup: true)
        #expect(flagged.isPerGroup == kind.canRunPerGroup)
        #expect(!ClassActivity(kind: kind).isPerGroup, "no flag, no groups")
    }

    @Test func theKindsThatCanRunPerGroupAreTheLeaderboardsAndTheRoundRobin() {
        #expect(
            ActivityKind.allCases.filter(\.canRunPerGroup) == [
                .beatTheInstructor, .bestMetric, .kingOfTheHill, .roundRobin,
            ])
    }
}
