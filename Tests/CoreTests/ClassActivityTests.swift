// Tests/CoreTests/ClassActivityTests.swift
//
// The manifest's optional `activity` block (docs/class-activities.md): it
// decodes with defaults, an ordinary manifest's bytes do not change, and the
// runner-facing projection drops it.

import Core
import Foundation
import Testing

@Suite struct ClassActivityTests {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    @Test func absentBlockDecodesToNilAndEncodesNoKey() throws {
        let plain = TestProperties(testSuites: [TestSuiteEntry(tier: .pub, script: "t.sh")])
        let json = try #require(String(data: encoder.encode(plain), encoding: .utf8))
        #expect(!json.contains("activity"))
        #expect(try decoder.decode(TestProperties.self, from: Data(json.utf8)).activity == nil)
    }

    @Test func blockRoundTripsThroughTestProperties() throws {
        let props = TestProperties(
            activity: ClassActivity(kind: .bestMetric, leaderboardVisibility: .visible))
        let decoded = try decoder.decode(TestProperties.self, from: encoder.encode(props))
        #expect(decoded.activity == props.activity)
        #expect(decoded.activity?.kind == .bestMetric)
        #expect(decoded.activity?.leaderboardVisibleToStudents == true)
    }

    /// A hand-authored block naming only the kind gets the safe default: hidden.
    @Test func leaderboardVisibilityDefaultsToHidden() throws {
        let json = Data(#"{"schemaVersion":1,"activity":{"kind":"beatTheInstructor"}}"#.utf8)
        let props = try decoder.decode(TestProperties.self, from: json)
        #expect(props.activity?.kind == .beatTheInstructor)
        #expect(props.activity?.leaderboardVisibility == .hidden)
        #expect(props.activity?.leaderboardVisibleToStudents == false)
    }

    /// The runner never reads the block, and stripping it is what protects an
    /// older runner from an `ActivityKind` case its build predates.
    @Test func runnerSanitizedDropsTheBlock() throws {
        let props = TestProperties(activity: ClassActivity(kind: .bestMetric))
        #expect(props.runnerSanitized().activity == nil)
        let json = try #require(String(data: encoder.encode(props.runnerSanitized()), encoding: .utf8))
        #expect(!json.contains("activity"))
    }

    /// Every kind this slice ships aggregates to a leaderboard, and each has
    /// chrome-length copy — the display name is a label, not a sentence.
    @Test(arguments: ActivityKind.allCases)
    func everyKindHasChromeCopyAndAnAggregation(kind: ActivityKind) {
        #expect(kind.aggregatesToLeaderboard)
        #expect(kind.displayName.split(separator: " ").count <= 3)
        #expect(!kind.summary.isEmpty)
        #expect(ActivityKind(rawValue: kind.rawValue) == kind)
    }
}
