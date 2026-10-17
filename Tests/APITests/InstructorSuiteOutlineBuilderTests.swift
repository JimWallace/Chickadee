// Tests/APITests/InstructorSuiteOutlineBuilderTests.swift
//
// The instructor's suite outline (notebook views NB6) built from a fixed
// manifest, solution and validation run: the sections and their items, each
// item's anchor and solution result, the unlinked items, the totals, and the
// issues.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct InstructorSuiteOutlineBuilderTests {

    private func solution() throws -> NotebookDefinitionScan {
        let cells: [[String: Any]] = [
            ["cell_type": "markdown", "metadata": [:], "source": "## Task 1: Count active days"],
            [
                "cell_type": "code", "metadata": [:], "outputs": [], "execution_count": NSNull(),
                "source": "def count_active_days(steps, goal):\n    return sum(s >= goal for s in steps)",
            ],
            ["cell_type": "markdown", "metadata": [:], "source": "## Task 2: Average heart rate"],
            [
                "cell_type": "code", "metadata": [:], "outputs": [], "execution_count": NSNull(),
                "source": "def average_heart_rate(readings):\n    return 0",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: ["nbformat": 4, "nbformat_minor": 5, "cells": cells])
        return scanNotebookDefinitions(data, language: .python)
    }

    private var manifest: TestProperties {
        TestProperties(
            testSuites: [
                TestSuiteEntry(
                    tier: .pub, script: "check_c1.py", name: "count_active_days is defined",
                    generatedByCheck: "c1", sectionID: "s1"),
                TestSuiteEntry(tier: .pub, script: "test_count.py", points: 2, sectionID: "s1"),
                TestSuiteEntry(tier: .secret, script: "test_all_missing.py", sectionID: "s2"),
                TestSuiteEntry(tier: .pub, script: "test_runs_fast.py", points: 0, sectionID: "s2"),
                TestSuiteEntry(tier: .pub, script: "test_loose.py"),
            ],
            language: .python,
            sections: [
                TestSuiteSection(id: "s1", name: "Task 1: Count active days"),
                TestSuiteSection(id: "s2", name: "Task 2: Average heart rate"),
            ],
            testItems: [.check(NotebookCheck(id: "c1", kind: .functionExists, variable: "count_active_days"))])
    }

    private var scripts: [String: String] {
        [
            "test_count.py": "assert count_active_days([1], 0) == 1",
            "test_all_missing.py": "assert average_heart_rate([None, None]) is None",
            "test_runs_fast.py": "import time",
            "test_loose.py": "print('ok')",
        ]
    }

    private func outcome(_ name: String, _ tier: TestTier, _ status: TestStatus, _ short: String = "") -> TestOutcome {
        TestOutcome(
            testName: name, testClass: nil, tier: tier, status: status, shortResult: short, longResult: nil,
            executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: false)
    }

    private var run: TestOutcomeCollection {
        let outcomes = [
            outcome("check_c1", .pub, .pass),
            outcome("test_count", .pub, .pass),
            outcome("test_all_missing", .secret, .fail, "ZeroDivisionError: division by zero"),
            outcome("test_runs_fast", .pub, .pass),
        ]
        return TestOutcomeCollection(
            submissionID: "val-1", testSetupID: "setup-1", attemptNumber: 1, buildStatus: .passed,
            compilerOutput: nil, outcomes: outcomes, totalTests: outcomes.count, passCount: 3, failCount: 1,
            errorCount: 0, timeoutCount: 0, executionTimeMs: 5, totalPoints: 5, earnedPoints: 3,
            runnerVersion: "test", timestamp: Date(timeIntervalSince1970: 100))
    }

    private func build(run: TestOutcomeCollection?) throws -> InstructorSuiteOutline {
        InstructorSuiteOutlineBuilder(
            manifest: manifest, notebook: try solution(), scriptSources: scripts,
            validationStatus: run == nil ? nil : "failed", solutionRun: run
        ).build()
    }

    @Test func eachSectionListsItsLinkedItemsInOrder() throws {
        let outline = try build(run: run)
        #expect(outline.version == 1)
        #expect(outline.sections.map(\.id) == ["s1", "s2", nil])
        #expect(outline.sections.map(\.label) == ["Task 1", "Task 2", nil])
        #expect(outline.sections.map(\.points) == [3, 1, 1])
        #expect(outline.sections[0].items.map(\.id) == ["check_c1.py", "test_count.py"])
        #expect(outline.sections[0].items.map(\.name) == ["count_active_days is defined", "test_count"])
        #expect(outline.sections[0].items.map(\.kind) == ["check", "script"])
        #expect(outline.sections[0].items[0].checkKind == "function_exists")
        #expect(outline.totals == .init(checks: 5, points: 5))
    }

    @Test func anItemIsAnchoredByTheNameItUsesOrItsSection() throws {
        let outline = try build(run: run)
        let count = outline.sections[0].items[1]
        #expect(count.anchor == .init(kind: "function", name: "count_active_days", source: "auto", ambiguous: false))
        // No name the solution defines: the item's section heading.
        let fast = try #require(outline.sections[1].items.first { $0.id == "test_runs_fast.py" })
        #expect(
            fast.anchor == .init(kind: "section", name: "Task 2: Average heart rate", source: "auto", ambiguous: false))
    }

    @Test func anItemThatLinksToNoCellIsUnlinked() throws {
        let outline = try build(run: run)
        #expect(outline.unlinked.map(\.id) == ["test_loose.py"])
        #expect(outline.unlinked[0].anchor == nil)
        #expect(outline.sections[2].items.isEmpty)
    }

    @Test func eachItemCarriesItsSolutionResultAndAFailureIsAnIssue() throws {
        let outline = try build(run: run)
        let missing = try #require(outline.sections[1].items.first { $0.id == "test_all_missing.py" })
        #expect(missing.tier == "secret")
        #expect(missing.solution == .init(result: "fail", detail: "ZeroDivisionError: division by zero"))
        #expect(outline.sections[0].items[0].solution == .init(result: "pass"))
        // Not in the run: no result, and no issue.
        #expect(outline.unlinked[0].solution == nil)
        #expect(outline.validation.issues == [.init(itemID: "test_all_missing.py", kind: "failsOnSolution")])
        #expect(outline.validation.status == "failed")
        #expect(outline.validation.solutionRunAt == Date(timeIntervalSince1970: 100))
    }

    @Test func anItemCarriesItsSourceItsGeneratorAndItsPin() throws {
        var pinned = manifest
        pinned.testSuites[1].anchor = "average_heart_rate"
        let outline = InstructorSuiteOutlineBuilder(
            manifest: pinned, notebook: try solution(), scriptSources: scripts, validationStatus: nil, solutionRun: nil
        ).build()
        let check = outline.sections[0].items[0]
        #expect(check.generatorID == "c1")
        #expect(check.source == nil)
        // The pin wins over the name the script uses.
        let count = try #require(outline.sections.flatMap(\.items).first { $0.id == "test_count.py" })
        #expect(count.generatorID == nil)
        #expect(count.source == "assert count_active_days([1], 0) == 1")
        #expect(count.anchor == .init(kind: "function", name: "average_heart_rate", source: "pinned", ambiguous: false))
    }

    @Test func beforeAnyRunThereAreNoResultsAndNoIssues() throws {
        let outline = try build(run: nil)
        #expect(outline.sections.flatMap(\.items).allSatisfy { $0.solution == nil })
        #expect(outline.validation.issues.isEmpty)
        #expect(outline.validation.status == nil)
        #expect(outline.validation.solutionRunAt == nil)
    }
}
