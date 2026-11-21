// Tests/CoreTests/Gamification/CoveredItemNamesScopeTests.swift
//
// `TestProperties.coveredItemNames(inScopeOf:)` for the scopes that name no
// set of items. `AchievementClassificationTests` covers a section scope and
// the nil scope. The coverage report showed that no test reached the other
// arms: a section scope with no ref, and each target kind that is not a set
// of items. Each must give an empty set, never every item in the suite.

import Testing

@testable import Core

@Suite struct CoveredItemNamesScopeTests {

    private static let props = TestProperties(
        testSuites: [
            TestSuiteEntry(tier: .pub, script: "publictest_a.py", sectionID: "bughunt"),
            TestSuiteEntry(tier: .pub, script: "publictest_b.py", sectionID: "gate"),
        ], language: nil)

    @Test func aSectionScopeWithNoRefCoversNothing() {
        #expect(Self.props.coveredItemNames(inScopeOf: AchievementTarget(kind: .section, ref: nil)).isEmpty)
    }

    /// Every kind but `section`, so a kind added later is checked too.
    @Test(arguments: TargetKind.allCases.filter { $0 != .section })
    func aScopeThatIsNotASetOfItemsCoversNothing(kind: TargetKind) {
        #expect(Self.props.coveredItemNames(inScopeOf: AchievementTarget(kind: kind, ref: "bughunt")).isEmpty)
    }

    @Test func theNilScopeStillCoversEveryItem() {
        #expect(Self.props.coveredItemNames(inScopeOf: nil) == ["publictest_a", "publictest_b"])
    }
}
