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

    /// The block's predicates ask the source, never the kind's name. A bot
    /// kind stages an opponent only once a file is chosen, so with none it
    /// grades as a slice-1 activity did; a kind whose opponents are
    /// submissions (the hill, the classmates) stages them, file or not.
    @Test(arguments: ActivityKind.allCases)
    func theBlockAsksTheSourceAndABotKindStagesOnlyAChosenFile(kind: ActivityKind) {
        let unchosen = ClassActivity(kind: kind)
        #expect(unchosen.takesAnOpponentFile == kind.opponentSource.stagesAnOpponent)
        let stagesSubmissions = kind.opponentSource.stagesAnOpponent && kind.opponentSource != .supportFile
        #expect(unchosen.stagesAnOpponent == stagesSubmissions)
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

    // MARK: - The champion source (slice 3)

    /// King of the hill stages the champion, and stages one whether or not a
    /// bot is chosen: the kind itself is worker-only.
    @Test func theHillKindStagesAChampionWithOrWithoutABot() {
        #expect(ActivityKind.kingOfTheHill.opponentSource == .champion)
        #expect(ActivityKind.kingOfTheHill.aggregatesToLeaderboard)
        #expect(ClassActivity(kind: .kingOfTheHill).stagesAnOpponent)
        #expect(ClassActivity(kind: .kingOfTheHill).takesAnOpponentFile)
        #expect(ClassActivity(kind: .kingOfTheHill, opponentFile: "bot.py").stagesAnOpponent)
    }

    /// Each source names the build capability a runner must advertise, and
    /// the two staging sources name different ones: a build that copies a
    /// file may predate staging a submission.
    @Test func eachSourceNamesItsOwnRunnerCapability() {
        #expect(ActivityOpponentSource.none.requiredRunnerCapability == nil)
        #expect(ActivityOpponentSource.supportFile.requiredRunnerCapability == .activityMatch)
        #expect(ActivityOpponentSource.champion.requiredRunnerCapability == .activityOpponentSubmission)
        #expect(ActivityOpponentSource.classmates.requiredRunnerCapability == .activityMatrix)
        for source in ActivityOpponentSource.allCases where source.stagesAnOpponent {
            #expect(source.requiredRunnerCapability != nil, "\(source) stages an opponent but gates nothing")
        }
        // Three staging sources, three tokens: a build that stages one
        // submission may predate staging a matrix of them.
        let tokens = ActivityOpponentSource.allCases.compactMap(\.requiredRunnerCapability?.name)
        #expect(Set(tokens).count == tokens.count)
    }

    // MARK: - The classmates source and the aggregation axis (slice 4)

    /// Round robin plays every classmate and keeps standings rather than a
    /// metric ranking; the kind is worker-only like the hill.
    @Test func theRoundRobinPlaysClassmatesAndKeepsStandings() {
        #expect(ActivityKind.roundRobin.opponentSource == .classmates)
        #expect(ActivityKind.roundRobin.aggregation == .standings)
        #expect(ActivityKind.roundRobin.aggregatesToLeaderboard)
        #expect(ClassActivity(kind: .roundRobin).stagesAnOpponent)
        #expect(ClassActivity(kind: .roundRobin).takesAnOpponentFile)
    }

    /// Every kind answers the aggregation axis, and the slice-1 and slice-3
    /// kinds keep the metric ranking they shipped with.
    @Test(arguments: ActivityKind.allCases)
    func everyKindAnswersTheAggregationAxis(kind: ActivityKind) {
        #expect(kind.aggregatesToLeaderboard)
        if kind.opponentSource == .classmates {
            #expect(kind.aggregation == .standings)
        } else {
            #expect(kind.aggregation == .leaderboard)
        }
    }

    @Test func theRoundRobinBlockRoundTrips() throws {
        let block = ClassActivity(kind: .roundRobin, leaderboardVisibility: .visible, opponentFile: "bot.py")
        let decoded = try decoder.decode(ClassActivity.self, from: encoder.encode(block))
        #expect(decoded == block)
        #expect(decoded.kind.opponentSource == .classmates)
    }
}
