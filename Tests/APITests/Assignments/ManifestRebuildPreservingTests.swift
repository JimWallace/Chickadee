// Tests/APITests/Assignments/ManifestRebuildPreservingTests.swift
//
// `makeWorkerManifestJSON(preserving:...)` copies the decoded manifest and
// replaces only the suite, so a rebuild cannot forget a field. It used to
// write a fresh dict from a hand-threaded list, and every such rebuild
// eventually forgot one. This pins the fields that were each lost once.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct ManifestRebuildPreservingTests {
    @Test func rebuildCarriesEveryPreservedField() throws {
        let original = try makeWorkerManifestJSON(
            testSuites: [
                ConfiguredSuiteEntry(
                    script: "publictest_a.sh", tier: "public", order: 1,
                    dependsOn: [], points: 2, displayName: "A")
            ],
            includeMakefile: true,
            gradingMode: "browser",
            submissionMode: "uploadOnly",
            requiredFiles: ["main.py"],
            timeLimitSeconds: 42,
            starterNotebook: "lab.ipynb",
            sections: [TestSuiteSection(id: "s1", name: "Warm-up")],
            globalVariables: [FamilyVariable(name: "n", value: .int(3))],
            datasets: [],
            language: nil,
            languageDeclared: true,
            minimumRunnerVersion: "0.5.100"
        )
        let props = try #require(decodeManifest(fromJSON: original))

        let rebuilt = try makeWorkerManifestJSON(preserving: props, testSuites: [], language: props.language)
        let after = try #require(decodeManifest(fromJSON: rebuilt))

        #expect(after.testSuites.isEmpty)
        #expect(after.makefile != nil)
        #expect(after.gradingMode == props.gradingMode)
        #expect(after.submissionMode == props.submissionMode)
        #expect(after.requiredFiles == ["main.py"])
        #expect(after.timeLimitSeconds == 42)
        #expect(after.starterNotebook == "lab.ipynb")
        #expect(after.sections.map(\.id) == ["s1"])
        #expect(after.globalVariables.map(\.name) == ["n"])
        #expect(after.language == nil)
        #expect(after.languageDeclared == true)
        #expect(after.minimumRunnerVersion == "0.5.100")
    }

    @Test func rebuildReplacesOnlyWhatTheCallerPasses() throws {
        let original = try makeWorkerManifestJSON(
            testSuites: [], includeMakefile: false,
            sections: [TestSuiteSection(id: "s1", name: "Warm-up")],
            language: .r, languageDeclared: true)
        let props = try #require(decodeManifest(fromJSON: original))

        let rebuilt = try makeWorkerManifestJSON(
            preserving: props, testSuites: [],
            sections: [TestSuiteSection(id: "s2", name: "Main")],
            language: .lua)
        let after = try #require(decodeManifest(fromJSON: rebuilt))
        #expect(after.sections.map(\.id) == ["s2"])
        #expect(after.language == .lua)
        #expect(after.languageDeclared == true)
    }

    /// `graderOnlyFiles` was never threaded through the old fresh-dict builder,
    /// so every suite edit silently dropped the marks. The copy keeps them,
    /// with the fields that already had to be remembered one by one.
    @Test func rebuildKeepsTheFieldsNoCallerNames() throws {
        let original = try makeWorkerManifestJSON(
            testSuites: [], includeMakefile: false,
            githubSubmission: true,
            achievements: [
                Achievement(
                    id: "a1", name: "Record", detail: "Holds the record.", scope: .record,
                    reward: AchievementReward(type: .title, label: "Record holder"),
                    recordDimension: .highestMetric)
            ],
            disabledBuiltInAwardIDs: ["first-try"],
            builtInAchievementsSeeded: true,
            datasets: [DatasetSpec(file: "data.csv", sampleSize: 5)],
            language: nil,
            activity: ClassActivity(kind: .bestMetric))
        var props = try #require(decodeManifest(fromJSON: original))
        props.graderOnlyFiles = ["answers.R"]

        let rebuilt = try makeWorkerManifestJSON(
            preserving: props,
            testSuites: [
                ConfiguredSuiteEntry(
                    script: "publictest_a.sh", tier: "public", order: 1,
                    dependsOn: [], points: 1, displayName: nil)
            ],
            language: nil)
        let after = try #require(decodeManifest(fromJSON: rebuilt))

        #expect(after.testSuites.map(\.script) == ["publictest_a.sh"])
        #expect(after.graderOnlyFiles == ["answers.R"])
        #expect(after.githubSubmission)
        #expect(after.achievements.map(\.id) == ["a1"])
        #expect(after.disabledBuiltInAwardIDs == ["first-try"])
        #expect(after.builtInAchievementsSeeded)
        #expect(after.datasets.map(\.file) == ["data.csv"])
        #expect(after.activity?.kind == .bestMetric)
    }

    @Test func aTierThatIsNotATierIsRefusedNotStored() throws {
        let props = TestProperties(language: nil)
        #expect(throws: WebAssignmentError.self) {
            try makeWorkerManifestJSON(
                preserving: props,
                testSuites: [
                    ConfiguredSuiteEntry(
                        script: "a.sh", tier: "support", order: 1,
                        dependsOn: [], points: 1, displayName: nil)
                ],
                language: nil)
        }
    }

    // MARK: - Script add and delete keep the achievements

    /// A manifest carrying one authored badge, one disabled built-in award and
    /// the curated flag: the fields the suite-rebuild wrappers once dropped
    /// (achievements audit A3).
    private func manifestWithAchievements() throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "test_a.sh")],
            language: nil,
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
}
