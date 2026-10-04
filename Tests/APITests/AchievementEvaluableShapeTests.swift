import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

/// The authoring shapes that nothing evaluates are refused at save time
/// (#2054, audit A17 and A18).
@Suite struct AchievementEvaluableShapeTests {

    private let manifest: String = {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "test_a.sh", sectionID: "s1")],
            sections: [TestSuiteSection(id: "s1", name: "One")])
        let data = (try? JSONEncoder().encode(props)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }()

    private func achievement(
        scope: AchievementScope, reward: RewardType, conditions: [AchievementCondition] = []
    ) -> Achievement {
        Achievement(
            id: "a", name: "A", scope: scope, conditions: conditions,
            reward: AchievementReward(type: reward, label: "A", points: reward == .points ? 1 : nil),
            classFraction: scope == .classWide ? 0.5 : nil,
            recordDimension: scope == .record ? .firstToSolve : nil)
    }

    // MARK: A17: a record needs its dimension

    @Test func aRecordWithoutADimensionIsRefused() {
        let row = AchievementRow(name: "Fastest", scope: "record")
        #expect(throws: WebAssignmentError.self) {
            try AchievementsEditing.achievement(from: row)
        }
        let blank = AchievementRow(name: "Fastest", scope: "record", recordDimension: "")
        #expect(throws: WebAssignmentError.self) {
            try AchievementsEditing.achievement(from: blank)
        }
    }

    @Test func aRecordWithADimensionIsAccepted() throws {
        let row = AchievementRow(name: "Fastest", scope: "record", recordDimension: "fastest")
        let record = try AchievementsEditing.achievement(from: row)
        #expect(record.recordDimension == .fastest)
    }

    // MARK: A18: scope and reward pairs that nothing evaluates

    @Test(arguments: [
        (AchievementScope.individual, RewardType.title),
        (.individual, .points),
        (.classWide, .badge),
        (.classWide, .title),
    ])
    func anUnevaluatedScopeAndRewardPairIsRefused(scope: AchievementScope, reward: RewardType) {
        #expect(throws: WebAssignmentError.self) {
            try AchievementsEditing.validate([achievement(scope: scope, reward: reward)], againstManifest: manifest)
        }
    }

    @Test(arguments: [
        (AchievementScope.individual, RewardType.badge),
        (.classWide, .points),
        (.record, .title),
    ])
    func theEvaluatedPairsAreAccepted(scope: AchievementScope, reward: RewardType) throws {
        try AchievementsEditing.validate([achievement(scope: scope, reward: reward)], againstManifest: manifest)
    }

    // MARK: A18: a target on a signal that ignores it

    @Test func aTargetOnAGradeConditionIsRefused() {
        let scoped = AchievementCondition(
            signal: .grade, comparator: .atLeast, value: 50,
            target: AchievementTarget(kind: .section, ref: "s1"))
        #expect(throws: WebAssignmentError.self) {
            try AchievementsEditing.validate(
                [achievement(scope: .individual, reward: .badge, conditions: [scoped])],
                againstManifest: manifest)
        }
    }

    @Test func theTargetsThatAreReadAreAccepted() throws {
        let test = AchievementCondition(
            signal: .testPass, comparator: .atLeast, value: 1,
            target: AchievementTarget(kind: .testPass, ref: "test_a.sh"))
        try AchievementsEditing.validate(
            [achievement(scope: .individual, reward: .badge, conditions: [test])],
            againstManifest: manifest)
        let items = AchievementCondition(
            signal: .itemsCovered, comparator: .atLeast, value: 1,
            target: AchievementTarget(kind: .section, ref: "s1"))
        try AchievementsEditing.validate(
            [achievement(scope: .classWide, reward: .points, conditions: [items])],
            againstManifest: manifest)
    }

    /// The shape check does not need a decodable manifest: a hand-authored
    /// manifest is exactly where these shapes come from.
    @Test func theShapeCheckRunsWithoutADecodableManifest() {
        #expect(throws: WebAssignmentError.self) {
            try AchievementsEditing.validate(
                [achievement(scope: .classWide, reward: .badge)], againstManifest: "not json")
        }
    }

    // MARK: A18: the dead sectionID field

    @Test func aStoredSectionIDStillDecodesAndIsNotWrittenBack() throws {
        let json = """
            {"id":"a","name":"A","scope":"individual","conditions":[],"match":"all",
             "reward":{"type":"badge","label":"A"},"sectionID":"s1"}
            """
        let decoded = try JSONDecoder().decode(Achievement.self, from: Data(json.utf8))
        #expect(decoded.id == "a")
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!encoded.contains("sectionID"))
    }
}
