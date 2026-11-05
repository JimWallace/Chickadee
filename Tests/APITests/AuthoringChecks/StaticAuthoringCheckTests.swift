// Tests/APITests/AuthoringChecks/StaticAuthoringCheckTests.swift
//
// The step-5 authoring checks (#2747): achievements that can never be
// awarded, a suite with no graded test, and data files students do not
// receive. Each builds an `AuthoringSnapshot` by hand.

import Core
import Testing

@testable import APIServer

@Suite struct StaticAuthoringCheckTests {
    private let suiteJSON = """
        {"schemaVersion":1,"testSuites":[\
        {"tier":"public","script":"test_a.py","points":1,"sectionID":"s1"},\
        {"tier":"public","script":"test_b.py","points":1,"sectionID":"s1"},\
        {"tier":"secret","script":"test_c.py","points":1}\
        ],"sections":[{"id":"s1","name":"Part 1"}],"timeLimitSeconds":10,\
        "graderOnlyFiles":["answers.csv"]}
        """

    private func snapshot(achievements: [Achievement] = []) throws -> AuthoringSnapshot {
        var manifest = try #require(decodeManifest(fromJSON: suiteJSON))
        manifest.achievements = achievements
        return AuthoringSnapshot(manifest: manifest)
    }

    private func badge(_ name: String, _ conditions: [AchievementCondition]) -> Achievement {
        Achievement(
            id: name, name: name, scope: .individual, conditions: conditions,
            reward: AchievementReward(type: .badge, label: name))
    }

    private func classGoal(_ name: String, _ conditions: [AchievementCondition]) -> Achievement {
        Achievement(
            id: name, name: name, scope: .classWide, conditions: conditions,
            reward: AchievementReward(type: .points, label: name, points: 2), classFraction: 0.5)
    }

    // MARK: - achievements.neverAwarded

    @Test func aTestPassRefToADeletedTestNeverFires() throws {
        let findings = AchievementReachabilityCheck().findings(
            in: try snapshot(achievements: [
                badge(
                    "Kept",
                    [
                        .init(
                            signal: .testPass, comparator: .atLeast, value: 1,
                            target: .init(kind: .testPass, ref: "test_a.py"))
                    ]),
                badge(
                    "Gone",
                    [
                        .init(
                            signal: .testPass, comparator: .atLeast, value: 1,
                            target: .init(kind: .testPass, ref: "test_z.py"))
                    ]),
            ]))
        #expect(findings.count == 1)
        #expect(findings.first?.message.contains("\"Gone\"") == true)
        #expect(findings.first?.message.contains("test_z.py") == true)
    }

    @Test func aUnionGoalAskingForMoreItemsThanItsScopeNeverFires() throws {
        let inSection = classGoal(
            "Section",
            [.init(signal: .itemsCovered, comparator: .atLeast, value: 3, target: .init(kind: .section, ref: "s1"))])
        let wholeSuite = classGoal("Whole", [.init(signal: .itemsCovered, comparator: .atLeast, value: 3)])
        let findings = AchievementReachabilityCheck().findings(in: try snapshot(achievements: [inSection, wholeSuite]))
        #expect(findings.count == 1)
        #expect(findings.first?.message.contains("cover 3 items, but only 2") == true)
    }

    @Test func aDeletedSectionAndAnUnevaluableGoalAreReported() throws {
        let deleted = classGoal(
            "Deleted",
            [.init(signal: .itemsCovered, comparator: .atLeast, value: 1, target: .init(kind: .section, ref: "gone"))])
        let shape = classGoal("Shape", [.init(signal: .attempts, comparator: .atMost, value: 3)])
        let messages = AchievementReachabilityCheck().findings(in: try snapshot(achievements: [deleted, shape]))
            .map(\.message)
        #expect(messages.contains { $0.contains("\"Deleted\"") && $0.contains("no longer exists") })
        #expect(messages.count == 2, "a dangling section is not also reported as too few items")
        #expect(messages.contains { $0.contains("\"Shape\"") && $0.contains("does not evaluate") })
    }

    // MARK: - points.noGradedTest

    @Test func noGradedTestFiresOnlyWhenEveryTestIsWorthZero() throws {
        var snapshot = try snapshot()
        #expect(NoGradedTestCheck().findings(in: snapshot).isEmpty)
        snapshot = AuthoringSnapshot(
            manifest: try #require(
                decodeManifest(
                    fromJSON:
                        #"{"schemaVersion":1,"testSuites":[{"tier":"public","script":"a.py","points":0}],"timeLimitSeconds":10}"#
                )))
        #expect(NoGradedTestCheck().findings(in: snapshot).map(\.checkID) == ["points.noGradedTest"])
    }

    // MARK: - files.missing

    @Test func missingDataFilesAreReportedOncePerFile() throws {
        var snapshot = try snapshot()
        snapshot.setupZipEntries = ["test_a.py", "data/visits.csv", "helpers.py", "answers.csv"]
        snapshot.notebookCodeCells = [
            nil,
            "df = pd.read_csv(\"data/visits.csv\")",
            "extra = pd.read_csv('./extra.csv')\nkey = pd.read_csv(\"answers.csv\")",
            "again = pd.read_csv(\"extra.csv\")\nurl = \"https://example.org/remote.csv\"",
        ]
        let findings = MissingDataFileCheck().findings(in: snapshot)
        #expect(findings.map(\.location) == [.notebookCell(2), .notebookCell(2)])
        #expect(findings[0].message.contains("opens extra.csv, which is not a support file"))
        #expect(findings[1].message.contains("answers.csv, which is grader-only"))
    }

    @Test func commentsAndWrittenFilesAreNotReported() throws {
        var snapshot = try snapshot()
        snapshot.setupZipEntries = ["test_a.py"]
        snapshot.notebookCodeCells = [
            "# e.g. data = pd.read_csv(\"example.csv\")\nx = 1  // \"also.csv\"",
            "summary.to_csv(\"out.csv\")\nwith open(\"log.txt\", \"w\") as f:\n    pass",
            "back = pd.read_csv(\"out.csv\")",
        ]
        #expect(MissingDataFileCheck().findings(in: snapshot).isEmpty)
    }

    @Test func anUnreadableZipSkipsTheFileCheck() throws {
        var snapshot = try snapshot()
        snapshot.notebookCodeCells = ["df = pd.read_csv(\"visits.csv\")"]
        #expect(MissingDataFileCheck().findings(in: snapshot).isEmpty)
    }

    /// The dataset writer ignores the grader-only mark, so a dataset is
    /// delivered whatever it says (`StudentWorkspaceFiles.delivered`).
    @Test func aDatasetIsDeliveredEvenWhenMarkedGraderOnly() throws {
        let manifest = try #require(
            decodeManifest(
                fromJSON: #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10,"graderOnlyFiles":["cases.csv"],"#
                    + #""datasets":[{"file":"cases.csv"}]}"#))
        #expect(StudentWorkspaceFiles.delivered(zipEntries: ["cases.csv"], manifest: manifest) == ["cases.csv"])
        #expect(
            StudentWorkspaceFiles.linkedSupportFiles(zipEntries: ["cases.csv", "h.py"], manifest: manifest) == ["h.py"])
    }

    @Test func aDisabledAwardIsNotReported() throws {
        var snapshot = try snapshot(achievements: [
            badge(
                "Off",
                [
                    .init(
                        signal: .testPass, comparator: .atLeast, value: 1,
                        target: .init(kind: .testPass, ref: "test_z.py"))
                ])
        ])
        var manifest = snapshot.manifest
        manifest.disabledBuiltInAwardIDs = ["Off"]
        snapshot = AuthoringSnapshot(manifest: manifest)
        #expect(AchievementReachabilityCheck().findings(in: snapshot).isEmpty)
    }
}
