// Tests/CoreTests/ClassActivityRunsPerGroupTests.swift
//
// The `runsPerGroup` field of the activity block (docs/lab-groups.md,
// slice 2): absent from every block that does not run per group, so a stored
// manifest keeps its bytes, and kept by every rebuild, so saving one of the
// Activity section's forms cannot turn it off.

import Core
import Foundation
import Testing

@Suite struct ClassActivityRunsPerGroupTests {

    private func json(_ activity: ClassActivity) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try #require(String(data: encoder.encode(activity), encoding: .utf8))
    }

    @Test func aBlockThatDoesNotRunPerGroupKeepsItsBytes() throws {
        let activity = ClassActivity(kind: .bestMetric)
        #expect(!activity.runsPerGroup)
        #expect(try json(activity) == #"{"kind":"bestMetric","leaderboardVisibility":"hidden"}"#)
    }

    @Test func anOlderBlockDecodesAsNotPerGroup() throws {
        let decoded = try JSONDecoder().decode(
            ClassActivity.self, from: Data(#"{"kind":"roundRobin","leaderboardVisibility":"visible"}"#.utf8))
        #expect(!decoded.runsPerGroup)
    }

    @Test func aPerGroupBlockRoundTrips() throws {
        let activity = ClassActivity(kind: .roundRobin, runsPerGroup: true)
        #expect(try json(activity).contains(#""runsPerGroup":true"#))
        let decoded = try JSONDecoder().decode(ClassActivity.self, from: Data(try json(activity).utf8))
        #expect(decoded == activity)
    }

    @Test func everyRebuildKeepsIt() {
        let activity = ClassActivity(kind: .beatTheInstructor, opponentFile: "bot.py", runsPerGroup: true)
        #expect(activity.withLeaderboardVisibility(.visible).runsPerGroup)
        #expect(activity.withOpponentFile(nil).runsPerGroup)
        #expect(activity.withWindow(nil).runsPerGroup)
        #expect(activity.withComposite(nil).runsPerGroup)
        #expect(!activity.withRunsPerGroup(false).runsPerGroup)
        #expect(activity.withRunsPerGroup(false).opponentFile == "bot.py", "and it keeps the rest")
    }
}
