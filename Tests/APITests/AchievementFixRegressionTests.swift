// Tests/APITests/AchievementFixRegressionTests.swift
//
// Regression tests for the 2026-07 achievements audit fixes:
//   A3 — the web suite editor's script add/delete manifest rebuilds must
//        preserve authored achievements + the built-in-award toggles.
//   A4 — classWide goals reject condition shapes the sweep can't evaluate.
//   A5 — a curated (seeded) manifest with no per-submission badges / records
//        suppresses the registry fallback at award time.
//   A6 — manifest-authored class records resolve to display badges.
//   A1/A17 — testPass refs are validated against the suite on save; ids must
//        be unique.

import Foundation
import Testing

@testable import APIServer
@testable import Core

@Suite struct AchievementFixRegressionTests {

    /// A manifest carrying one authored badge, one disabled built-in, and the
    /// curated flag — the fields the suite-rebuild wrappers used to drop.
    private func manifestWithAchievements() throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "test_a.sh")],
            achievements: [
                Achievement(
                    id: "custom_badge", name: "Custom", scope: .individual,
                    conditions: [
                        AchievementCondition(signal: .grade, comparator: .atLeast, value: 90)
                    ],
                    reward: AchievementReward(type: .badge, label: "Custom"))
            ],
            disabledBuiltInAwardIDs: ["speed_demon"],
            builtInAchievementsSeeded: true)
        let data = try JSONEncoder().encode(props)
        return try #require(String(bytes: data, encoding: .utf8))
    }

    // MARK: - A3: script add/delete preserves achievements

    @Test func addingScriptPreservesAchievementsAndToggles() throws {
        let entry = ConfiguredSuiteEntry(
            script: "test_b.sh", tier: "public", order: 2,
            dependsOn: [], points: 1, displayName: nil)
        let updated = try #require(
            updateManifestAddingScript(manifestJSON: manifestWithAchievements(), entry: entry))
        let props = try JSONDecoder().decode(TestProperties.self, from: Data(updated.utf8))
        #expect(props.testSuites.count == 2)
        #expect(props.achievements.map(\.id) == ["custom_badge"])
        #expect(props.disabledBuiltInAwardIDs == ["speed_demon"])
        #expect(props.builtInAchievementsSeeded)
    }

    @Test func removingScriptPreservesAchievementsAndToggles() throws {
        let updated = try #require(
            updateManifestRemovingScript(
                manifestJSON: try manifestWithAchievements(), filename: "test_a.sh"))
        let props = try JSONDecoder().decode(TestProperties.self, from: Data(updated.utf8))
        #expect(props.testSuites.isEmpty)
        #expect(props.achievements.map(\.id) == ["custom_badge"])
        #expect(props.disabledBuiltInAwardIDs == ["speed_demon"])
        #expect(props.builtInAchievementsSeeded)
    }

    // MARK: - A5: curated-empty manifests suppress the registry fallback

    private func setup(withProps props: TestProperties) throws -> APITestSetup {
        let data = try JSONEncoder().encode(props)
        return APITestSetup(
            id: "afr_setup",
            manifest: try #require(String(bytes: data, encoding: .utf8)),
            zipPath: "/tmp/afr.zip",
            courseID: UUID())
    }

    @Test func curatedEmptyManifestAwardsNoBuiltIns() throws {
        let curated = TestProperties(achievements: [], builtInAchievementsSeeded: true)
        #expect(BuiltInAchievements.manifestPerSubmission(props: curated) == [])
        let curatedSetup = try setup(withProps: curated)
        #expect(BuiltInAchievements.classRecordsForAward(in: curatedSetup, disabled: []).isEmpty)
    }

    @Test func unseededManifestStillFallsBackToRegistry() throws {
        let unseeded = TestProperties()
        #expect(BuiltInAchievements.manifestPerSubmission(props: unseeded) == nil)
        let unseededSetup = try setup(withProps: unseeded)
        let records = BuiltInAchievements.classRecordsForAward(in: unseededSetup, disabled: [])
        #expect(records.map(\.id).contains("trailblazer"))
    }

    // MARK: - A6: manifest-authored records display

    @Test func customRecordResolvesToItsAuthoredBadge() {
        let custom = Achievement(
            id: "first_diagnosis", name: "First Diagnosis",
            detail: "First to a working classifier.",
            scope: .record,
            reward: AchievementReward(type: .title, label: "First Diagnosis"),
            recordDimension: .firstToSolve)
        let badge = AchievementBadge.forClassAchievement(
            "first_diagnosis", manifestAchievements: [custom])
        #expect(badge?.label == "First Diagnosis")
        #expect(badge?.tooltip == "First to a working classifier.")
        // A renamed built-in id shows the instructor's name, not the registry's.
        let renamed = Achievement(
            id: "trailblazer", name: "First Course",
            scope: .record,
            reward: AchievementReward(type: .title, label: "First Course"),
            recordDimension: .firstToSolve)
        #expect(
            AchievementBadge.forClassAchievement(
                "trailblazer", manifestAchievements: [renamed])?.label == "First Course")
        // Registry fallback still works, unknown IDs still return nil.
        #expect(AchievementBadge.forClassAchievement("trailblazer")?.label == "Trailblazer")
        #expect(AchievementBadge.forClassAchievement("no_such_id") == nil)
    }

    // MARK: - A4: classWide condition shapes

    @Test func classWideRejectsNonGradeConditions() {
        let row = AchievementRow(
            name: "Goal", scope: "classWide",
            conditions: [ConditionRow(signal: "attempts", comparator: "atMost", value: 3)],
            classPercent: 80, points: 1)
        #expect(throws: WebAssignmentError.self) {
            _ = try AchievementsEditing.achievement(from: row)
        }
        let multi = AchievementRow(
            name: "Goal", scope: "classWide",
            conditions: [
                ConditionRow(signal: "grade", comparator: "atLeast", value: 80),
                ConditionRow(signal: "grade", comparator: "atLeast", value: 90),
            ],
            classPercent: 80, points: 1)
        #expect(throws: WebAssignmentError.self) {
            _ = try AchievementsEditing.achievement(from: multi)
        }
        let atMost = AchievementRow(
            name: "Goal", scope: "classWide",
            conditions: [ConditionRow(signal: "grade", comparator: "atMost", value: 80)],
            classPercent: 80, points: 1)
        #expect(throws: WebAssignmentError.self) {
            _ = try AchievementsEditing.achievement(from: atMost)
        }
        // The supported shapes still author fine.
        let single = AchievementRow(
            name: "Goal", scope: "classWide",
            conditions: [ConditionRow(signal: "grade", comparator: "atLeast", value: 80)],
            classPercent: 80, points: 1)
        #expect((try? AchievementsEditing.achievement(from: single)) != nil)
        let empty = AchievementRow(
            name: "Goal", scope: "classWide", conditions: [], classPercent: 80, points: 1)
        #expect((try? AchievementsEditing.achievement(from: empty)) != nil)
    }

    // MARK: - A1/A17: save-time validation

    @Test func validateRejectsDuplicateIDsAndUnknownRefs() throws {
        let manifest = try manifestWithAchievements()  // suite: test_a.sh
        func badge(_ id: String, ref: String? = nil) -> Achievement {
            Achievement(
                id: id, name: id, scope: .individual,
                conditions: ref.map {
                    [
                        AchievementCondition(
                            signal: .testPass, comparator: .atLeast, value: 1,
                            target: AchievementTarget(kind: .testPass, ref: $0))
                    ]
                } ?? [],
                reward: AchievementReward(type: .badge, label: id))
        }
        #expect(throws: WebAssignmentError.self) {
            try AchievementsEditing.validate(
                [badge("dup"), badge("dup")], againstManifest: manifest)
        }
        #expect(throws: WebAssignmentError.self) {
            try AchievementsEditing.validate(
                [badge("b", ref: "no_such_test.py")], againstManifest: manifest)
        }
        // Filename and stem both resolve.
        try AchievementsEditing.validate([badge("b", ref: "test_a.sh")], againstManifest: manifest)
        try AchievementsEditing.validate([badge("b", ref: "test_a")], againstManifest: manifest)
    }
}
