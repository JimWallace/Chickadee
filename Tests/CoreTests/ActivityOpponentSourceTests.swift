// Tests/CoreTests/ActivityOpponentSourceTests.swift
//
// The opponent axis (docs/class-activities.md, slice 2): every kind answers
// it, the block carries the opponent file without changing a slice-1 block's
// bytes, and the two rebuilders keep each other's field.

import Core
import Foundation
import Testing

@Suite struct ActivityOpponentSourceTests {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    /// The two kinds this build ships sit on opposite sides of the axis, so
    /// every opponent-dependent seam has one case of each to be tested on.
    @Test func theBotKindStagesAnOpponentAndTheMetricKindDoesNot() {
        #expect(ActivityKind.beatTheInstructor.opponentSource == .supportFile)
        #expect(ActivityKind.bestMetric.opponentSource == .none)
        #expect(ActivityOpponentSource.supportFile.stagesAnOpponent)
        #expect(!ActivityOpponentSource.none.stagesAnOpponent)
    }

    /// The block's predicates ask the source, never the kind's name — and an
    /// opponent is staged only once a file is chosen, so a bot kind with none
    /// grades as a slice-1 activity did.
    @Test(arguments: ActivityKind.allCases)
    func theBlockAsksTheSourceAndStagesOnlyAChosenFile(kind: ActivityKind) {
        let unchosen = ClassActivity(kind: kind)
        #expect(unchosen.takesAnOpponentFile == kind.opponentSource.stagesAnOpponent)
        #expect(!unchosen.stagesAnOpponent)
        let chosen = ClassActivity(kind: kind, opponentFile: "bot.py")
        #expect(chosen.stagesAnOpponent == kind.opponentSource.stagesAnOpponent)
    }

    @Test func opponentFileRoundTrips() throws {
        let block = ClassActivity(kind: .beatTheInstructor, opponentFile: "bot.py")
        let decoded = try decoder.decode(ClassActivity.self, from: encoder.encode(block))
        #expect(decoded == block)
        #expect(decoded.opponentFile == "bot.py")
    }

    /// A slice-1 block — no `opponentFile` key — decodes to nil and encodes
    /// without the key, so an existing manifest's bytes do not change.
    @Test func absentOpponentFileIsNilAndStaysAbsent() throws {
        let json = Data(#"{"kind":"beatTheInstructor","leaderboardVisibility":"hidden"}"#.utf8)
        let block = try decoder.decode(ClassActivity.self, from: json)
        #expect(block.opponentFile == nil)
        let reencoded = try #require(String(data: encoder.encode(block), encoding: .utf8))
        #expect(!reencoded.contains("opponentFile"))
    }

    /// The visibility toggle and the opponent picker each rebuild the block
    /// from the stored one; neither may drop the other's field.
    @Test func rebuildersKeepTheOtherField() {
        let block = ClassActivity(
            kind: .beatTheInstructor, leaderboardVisibility: .visible, opponentFile: "bot.py")
        #expect(block.withLeaderboardVisibility(.hidden).opponentFile == "bot.py")
        #expect(block.withOpponentFile("other.py").leaderboardVisibility == .visible)
        #expect(block.withOpponentFile(nil).opponentFile == nil)
        #expect(block.withOpponentFile(nil).kind == .beatTheInstructor)
    }

    /// The runner-facing projection still drops the whole block, opponent
    /// file included: the file travels on `Job.opponent`, never the manifest.
    @Test func runnerSanitizedDropsTheOpponentFileWithTheBlock() throws {
        let props = TestProperties(
            activity: ClassActivity(kind: .beatTheInstructor, opponentFile: "bot.py"))
        let json = try #require(String(data: encoder.encode(props.runnerSanitized()), encoding: .utf8))
        #expect(!json.contains("bot.py"))
        #expect(!json.contains("activity"))
    }
}
