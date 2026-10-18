// Tests/APITests/Notebooks/NotebookGuideBuilderTests.swift
//
// The student guide (`NotebookGuide`, notebook views brief NB3) built from a
// fixed manifest, solution, starter and attempt. These tests pin the payload
// shape, that no secret or release detail reaches it, the task statuses, and
// the starter sources the editor compares cells with.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct NotebookGuideBuilderTests {

    private enum Cell {
        case markdown(String, tags: [String] = [])
        case code(String)
    }

    private func notebook(_ cells: [Cell]) throws -> Data {
        let json: [[String: Any]] = cells.map { cell in
            switch cell {
            case .markdown(let source, let tags):
                return ["cell_type": "markdown", "metadata": ["tags": tags], "source": source]
            case .code(let source):
                return [
                    "cell_type": "code", "metadata": [:], "source": source, "outputs": [],
                    "execution_count": NSNull(),
                ]
            }
        }
        return try JSONSerialization.data(withJSONObject: ["nbformat": 4, "nbformat_minor": 5, "cells": json])
    }

    private var manifest: TestProperties {
        TestProperties(
            testSuites: [
                TestSuiteEntry(
                    tier: .pub, script: "check_c1.py", name: "count_active_days is defined",
                    generatedByCheck: "c1", sectionID: "s1"),
                TestSuiteEntry(tier: .pub, script: "test_count.py", sectionID: "s1"),
                TestSuiteEntry(tier: .secret, script: "secret_count.py", sectionID: "s1"),
                TestSuiteEntry(
                    tier: .pub, script: "test_skip_missing.py", points: 2, sectionID: "s2",
                    hint: "Check each reading with `is None`.", failureDetail: .actualOnly),
                TestSuiteEntry(
                    tier: .release, script: "release_hr.py", sectionID: "s2", hint: "A release hint."),
            ],
            language: .python,
            sections: [
                TestSuiteSection(id: "s1", name: "Task 1: Count active days"),
                TestSuiteSection(id: "s2", name: "Average heart rate"),
            ],
            testItems: [.check(NotebookCheck(id: "c1", kind: .functionExists, variable: "count_active_days"))])
    }

    private var scripts: [String: String] {
        [
            "test_count.py": "assert count_active_days([1], 0) == 1",
            "secret_count.py": "assert count_active_days([], 0) == 0",
            "test_skip_missing.py": "assert average_heart_rate([None, 60]) == 60",
            "release_hr.py": "assert average_heart_rate([60]) == 60",
        ]
    }

    private func solution() throws -> NotebookDefinitionScan {
        scanNotebookDefinitions(
            try notebook([
                .markdown("## Task 1: Count active days"),
                .code("def count_active_days(steps, goal):\n    return sum(s >= goal for s in steps)"),
                .markdown("## Average heart rate"),
                .code("def average_heart_rate(readings):\n    return 0"),
            ]), language: .python)
    }

    private func starter() throws -> Data {
        try notebook([
            .markdown("## Task 1: Count active days"),
            .code("def count_active_days(steps, goal):   \r\n    # your code here\r\n    ...\n\n"),
            .markdown("## Average heart rate"),
            .code("def average_heart_rate(readings):\n    ..."),
            .markdown("Explain your choice.", tags: ["reflection"]),
        ])
    }

    private func outcome(_ name: String, _ tier: TestTier, _ status: TestStatus, _ short: String = "") -> TestOutcome {
        TestOutcome(
            testName: name, testClass: nil, tier: tier, status: status, shortResult: short,
            longResult: status == .pass ? nil : "Traceback (most recent call last):\nSECRET-LONG-OUTPUT",
            executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 2, isFirstPassSuccess: false)
    }

    private func collection(_ outcomes: [TestOutcome]) -> TestOutcomeCollection {
        TestOutcomeCollection(
            submissionID: "sub-2", testSetupID: "setup-1", attemptNumber: 2, buildStatus: .passed,
            compilerOutput: nil, outcomes: outcomes, totalTests: outcomes.count,
            passCount: outcomes.filter { $0.status == .pass }.count,
            failCount: outcomes.filter { $0.status == .fail }.count, errorCount: 0, timeoutCount: 0,
            executionTimeMs: 5, totalPoints: 6, earnedPoints: 3, runnerVersion: "test",
            timestamp: Date(timeIntervalSince1970: 0))
    }

    private var graded: TestOutcomeCollection {
        collection([
            outcome("check_c1", .pub, .pass),
            outcome("test_count", .pub, .pass),
            outcome("secret_count", .secret, .fail, "SECRET-SHORT: expected 0 got 1"),
            outcome("test_skip_missing", .pub, .fail, "expected: 60\ngot: TypeError"),
            outcome("release_hr", .release, .fail, "RELEASE-SHORT: expected 60"),
        ])
    }

    private func build(attempt: NotebookGuideBuilder.AttemptInput?) throws -> NotebookGuide {
        NotebookGuideBuilder(
            manifest: manifest, solution: try solution(), starter: try starter(),
            scriptSources: scripts, attempt: attempt
        ).build()
    }

    // MARK: - Shape

    @Test func aGradedAttemptProducesTheDocumentedPayload() throws {
        let guide = try build(attempt: .init(submissionID: "sub-2", number: 2, collection: graded))
        #expect(guide.version == 1)
        #expect(guide.language == "python")
        #expect(
            guide.attempt
                == .init(
                    number: 2, pending: false, percent: 50, points: 3, pointsPossible: 6, url: "/submissions/sub-2"))
        #expect(guide.tasks.count == 2)

        let task1 = guide.tasks[0]
        #expect(task1.sectionID == "s1")
        #expect(task1.label == "Task 1")
        #expect(task1.name == "Count active days")
        #expect(task1.points == 3)
        #expect(task1.anchors == [NotebookGuide.Anchor(kind: "function", name: "count_active_days")])
        #expect(task1.status == "pass")
        #expect(task1.checks.map(\.name) == ["count_active_days is defined", "test_count"])
        #expect(task1.checks.map(\.kind) == ["check", "script"])
        #expect(task1.hiddenCount == 1)

        let task2 = guide.tasks[1]
        #expect(task2.label == nil)
        #expect(task2.name == "Average heart rate")
        #expect(task2.points == 3)
        #expect(task2.status == "fail")
        #expect(task2.checks.count == 1)
        #expect(task2.checks[0].result == "fail")
        #expect(task2.checks[0].hint == "Check each reading with `is None`.")
        #expect(task2.hiddenCount == 1)

        #expect(guide.reflections == [.init(label: "Reflection", tag: "reflection", readBy: "course staff")])
    }

    @Test func noSecretOrReleaseDetailLeavesTheBuilder() throws {
        let guide = try build(attempt: .init(submissionID: "sub-2", number: 2, collection: graded))
        let json = try #require(String(bytes: try JSONEncoder().encode(guide), encoding: .utf8))
        #expect(!json.contains("SECRET"))
        #expect(!json.contains("RELEASE"))
        #expect(!json.contains("secret_count"))
        #expect(!json.contains("release_hr"))
        #expect(!json.contains("A release hint."))
        // Only what the results page shows: the short result, never the
        // traceback.
        #expect(!json.contains("Traceback"))
        // The solution's code never reaches the payload.
        #expect(!json.contains("sum(s >= goal"))
    }

    @Test func aCheckDetailFollowsItsFailureDetailSetting() throws {
        let guide = try build(attempt: .init(submissionID: "sub-2", number: 2, collection: graded))
        let detail = try #require(guide.tasks[1].checks[0].detail)
        #expect(!detail.contains("expected: 60"))
    }

    // MARK: - States

    @Test func beforeTheFirstSubmissionEveryTaskIsFreshAndNoCheckHasAResult() throws {
        let guide = try build(attempt: nil)
        #expect(guide.attempt == nil)
        #expect(guide.tasks.map(\.status) == ["fresh", "fresh"])
        #expect(guide.tasks.flatMap(\.checks).allSatisfy { $0.result == nil && $0.detail == nil && $0.hint == nil })
    }

    @Test func aSubmissionStillGradingIsPending() throws {
        let guide = try build(attempt: .init(submissionID: "sub-3", number: 3, collection: nil))
        #expect(guide.attempt == .init(number: 3, pending: true, url: "/submissions/sub-3"))
        #expect(guide.tasks.map(\.status) == [nil, nil])
    }

    @Test func aTaskWithOnlyHiddenTestsHasNoStatus() throws {
        var props = manifest
        props.testSuites = props.testSuites.filter { $0.sectionID == "s1" || $0.tier != .pub }
        let guide = NotebookGuideBuilder(
            manifest: props, solution: try solution(), starter: try starter(), scriptSources: scripts,
            attempt: .init(submissionID: "sub-2", number: 2, collection: graded)
        ).build()
        #expect(guide.tasks[1].checks.isEmpty)
        #expect(guide.tasks[1].status == nil)
    }

    // MARK: - Starter sources

    @Test func starterSourcesAreKeyedByAnchorAndNormalized() throws {
        let guide = try build(attempt: nil)
        #expect(
            guide.starterSources["count_active_days"]
                == "def count_active_days(steps, goal):\n    # your code here\n    ...")
        #expect(guide.starterSources["average_heart_rate"] == "def average_heart_rate(readings):\n    ...")
    }

    @Test func aSectionAnchorIsKeyedBySection() throws {
        var props = manifest
        props.testSuites = [TestSuiteEntry(tier: .pub, script: "test_plot.py", sectionID: "s2")]
        let guide = NotebookGuideBuilder(
            manifest: props, solution: try solution(), starter: try starter(),
            scriptSources: ["test_plot.py": "assert True"], attempt: nil
        ).build()
        #expect(guide.tasks[1].anchors == [NotebookGuide.Anchor(kind: "section", name: "Average heart rate")])
        #expect(guide.starterSources["section:Average heart rate"] == "def average_heart_rate(readings):\n    ...")
    }

    @Test func checksInNoSectionFormALastTask() throws {
        var props = manifest
        props.testSuites.append(TestSuiteEntry(tier: .pub, script: "test_extra.py"))
        let guide = NotebookGuideBuilder(
            manifest: props, solution: try solution(), starter: nil, scriptSources: [:], attempt: nil
        ).build()
        let last = try #require(guide.tasks.last)
        #expect(last.sectionID == nil)
        #expect(last.name == "Other checks")
        #expect(last.anchors.isEmpty)
        #expect(guide.starterSources.isEmpty)
    }

    @Test func aHiddenTestsTargetNeverBecomesAnAnchor() throws {
        var props = manifest
        // A secret test that names a function no public test names.
        props.testSuites.append(TestSuiteEntry(tier: .secret, script: "secret_hr.py", sectionID: "s1"))
        var sources = scripts
        sources["secret_hr.py"] = "assert average_heart_rate([1]) == 1"
        let guide = NotebookGuideBuilder(
            manifest: props, solution: try solution(), starter: try starter(), scriptSources: sources,
            attempt: nil
        ).build()
        #expect(guide.tasks[0].anchors.map(\.name) == ["count_active_days"])
    }

    @Test func aTaskWithOnlyHiddenTestsPointsAtItsHeading() throws {
        var props = manifest
        props.testSuites = props.testSuites.filter { $0.sectionID == "s1" || $0.tier != .pub }
        let guide = NotebookGuideBuilder(
            manifest: props, solution: try solution(), starter: try starter(), scriptSources: scripts,
            attempt: nil
        ).build()
        #expect(guide.tasks[1].anchors == [NotebookGuide.Anchor(kind: "section", name: "Average heart rate")])
        #expect(guide.tasks[1].status == "fresh")
    }

    @Test func anEntryInADeletedSectionJoinsTheLastTask() throws {
        var props = manifest
        props.testSuites.append(TestSuiteEntry(tier: .pub, script: "test_orphan.py", points: 4, sectionID: "gone"))
        let guide = NotebookGuideBuilder(
            manifest: props, solution: try solution(), starter: nil, scriptSources: [:], attempt: nil
        ).build()
        let last = try #require(guide.tasks.last)
        #expect(last.sectionID == nil)
        #expect(last.points == 4)
        #expect(last.checks.map(\.name) == ["test_orphan"])
    }

    @Test func aPublicCheckWithNoOutcomeLeavesTheStatusUnknown() throws {
        let partial = collection([outcome("check_c1", .pub, .pass)])
        let guide = try build(attempt: .init(submissionID: "sub-2", number: 2, collection: partial))
        #expect(guide.tasks[0].status == nil)
    }

    @Test func aNameTheSolutionDoesNotDefineHasTheKindName() throws {
        var props = manifest
        props.testItems = [.check(NotebookCheck(id: "c1", kind: .functionExists, variable: "not_written_yet"))]
        let guide = NotebookGuideBuilder(
            manifest: props, solution: try solution(), starter: nil, scriptSources: scripts, attempt: nil
        ).build()
        #expect(guide.tasks[0].anchors.first == NotebookGuide.Anchor(kind: "name", name: "not_written_yet"))
    }

    @Test(arguments: [
        ("Task 2: Average heart rate", "Task 2", "Average heart rate"),
        ("Average heart rate", nil, "Average heart rate"),
        (": odd", nil, ": odd"),
    ])
    func aHeadingSplitsIntoLabelAndName(heading: String, label: String?, name: String) {
        let split = NotebookGuideBuilder.splitHeading(heading)
        #expect(split.label == label)
        #expect(split.name == name)
    }
}
