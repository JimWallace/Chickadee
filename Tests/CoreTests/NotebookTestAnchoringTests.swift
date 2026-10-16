// Tests/CoreTests/NotebookTestAnchoringTests.swift
//
// `NotebookTestAnchoring` links each suite item to a notebook cell by name
// (notebook views brief, NB3). These tests pin each resolution rule in order,
// the ambiguous and unlinked cases, a shadowed redefinition, the
// per-language variable scan, and an unsupported language.

import Foundation
import Testing

@testable import Core

@Suite struct NotebookTestAnchoringTests {

    private enum Cell {
        case markdown(String)
        case code(String)
    }

    private func notebook(_ cells: [Cell]) throws -> Data {
        let json: [[String: Any]] = cells.map { cell in
            switch cell {
            case .markdown(let source):
                return ["cell_type": "markdown", "metadata": [:], "source": source]
            case .code(let source):
                return [
                    "cell_type": "code", "metadata": [:], "source": source, "outputs": [],
                    "execution_count": NSNull(),
                ]
            }
        }
        return try JSONSerialization.data(withJSONObject: ["nbformat": 4, "nbformat_minor": 5, "cells": json])
    }

    private var solution: NotebookDefinitionScan {
        get throws {
            let data = try notebook([
                .code("import pandas as pd\nGOAL = 8000"),
                .markdown("## Task 1: Count active days"),
                .code("def count_active_days(steps, goal):\n    return sum(s >= goal for s in steps)"),
                .markdown("## Task 2: Average heart rate"),
                .code("def average_heart_rate(readings):\n    return 0\n\nsummary = average_heart_rate([])"),
                .markdown("## Task 4: Plot the week"),
                .code("plt.bar(range(7), week)"),
            ])
            return scanNotebookDefinitions(data, language: .python)
        }
    }

    // MARK: - The definitions scan

    @Test func theScanFindsFunctionsVariablesSectionsAndTheirCells() throws {
        let scan = try solution
        #expect(scan.unsupportedReason == nil)
        #expect(
            scan.definition(of: "count_active_days")
                == NotebookDefinition(name: "count_active_days", kind: .function, cellIndex: 2))
        #expect(scan.definition(of: "GOAL") == NotebookDefinition(name: "GOAL", kind: .variable, cellIndex: 0))
        #expect(scan.definition(of: "summary")?.cellIndex == 4)
        #expect(scan.namesInOrder == ["GOAL", "count_active_days", "average_heart_rate", "summary"])
        #expect(
            scan.sections.map(\.name) == [
                "Task 1: Count active days", "Task 2: Average heart rate", "Task 4: Plot the week",
            ])
        #expect(scan.firstCodeCell(inSection: "Task 4: Plot the week") == 6)
    }

    @Test func aComparisonOrAnIndentedAssignmentIsNotADefinition() throws {
        let data = try notebook([.code("if x == 1:\n    y = 2\nassert z == 3\n_private = 4\ntyped: int = 5")])
        let scan = scanNotebookDefinitions(data, language: .python)
        #expect(scan.namesInOrder == ["typed"])
    }

    @Test func aRedefinitionShadowsTheEarlierOne() throws {
        let data = try notebook([
            .code("def f(x):\n    return 1"), .markdown("## Later"), .code("def f(x):\n    return 2"),
        ])
        let scan = scanNotebookDefinitions(data, language: .python)
        #expect(scan.definition(of: "f")?.cellIndex == 2)
        let anchor = NotebookTestAnchoring.resolve(
            NotebookAnchorRequest(target: "f", targetRule: .check), solution: scan)
        #expect(anchor.cellIndex(in: scan) == 2)
    }

    @Test(arguments: [
        (
            AssignmentLanguage.r, "count_days <- function(steps, goal) {\n  sum(steps >= goal)\n}\ngoal.steps <- 8000",
            ["count_days", "goal.steps"]
        ),
        (
            .lua, "local function count_days(steps, goal)\n  return 0\nend\nlocal goal = 8000\ntotal = 0",
            ["count_days", "goal", "total"]
        ),
        (.octave, "function n = count_days(steps, goal)\n  n = 0;\nend\ngoal = 8000;", ["count_days", "goal"]),
    ])
    func eachKernelLanguageIsRead(language: AssignmentLanguage, source: String, names: [String]) throws {
        let scan = scanNotebookDefinitions(try notebook([.code(source)]), language: language)
        #expect(scan.unsupportedReason == nil)
        #expect(Set(scan.namesInOrder) == Set(names))
    }

    @Test(arguments: [AssignmentLanguage.cpp, .racket, .java])
    func anUploadOnlyLanguageIsUnsupportedNotEmpty(language: AssignmentLanguage) throws {
        let scan = scanNotebookDefinitions(
            try notebook([.markdown("## Task 1"), .code("int x = 1;")]), language: language)
        #expect(scan.unsupportedReason != nil)
        #expect(scan.definitions.isEmpty)
        #expect(scan.sections.map(\.name) == ["Task 1"])
    }

    @Test func noDeclaredLanguageIsUnsupported() throws {
        let scan = scanNotebookDefinitions(try notebook([.code("x = 1")]), language: nil)
        #expect(scan.unsupportedReason != nil)
    }

    // MARK: - Resolution, rule by rule

    @Test func aPinnedAnchorWinsOverEverything() throws {
        let request = NotebookAnchorRequest(
            pinned: "summary", target: "count_active_days", targetRule: .check,
            scriptSource: "average_heart_rate([])", sectionName: "Task 1: Count active days")
        let anchor = NotebookTestAnchoring.resolve(request, solution: try solution)
        #expect(anchor == NotebookAnchor(kind: .name, name: "summary", rule: .pinned))
        #expect(anchor.cellIndex(in: try solution) == 4)
    }

    @Test func aCheckAnchorsToTheNameItReads() throws {
        let manifest = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "check_c1.py", generatedByCheck: "c1")],
            language: .python,
            testItems: [.check(NotebookCheck(id: "c1", kind: .functionExists, variable: "average_heart_rate"))])
        let request = NotebookTestAnchoring.request(for: manifest.testSuites[0], in: manifest)
        let anchor = NotebookTestAnchoring.resolve(request, solution: try solution)
        #expect(anchor == NotebookAnchor(kind: .name, name: "average_heart_rate", rule: .check))
    }

    @Test func aFigureCheckFallsBackToItsSection() throws {
        let manifest = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "check_fig.py", generatedByCheck: "fig", sectionID: "s4")],
            language: .python,
            sections: [TestSuiteSection(id: "s4", name: "Task 4: Plot the week")],
            testItems: [.check(NotebookCheck(id: "fig", kind: .figureCount, sectionID: "s4", minFigures: 1))])
        let request = NotebookTestAnchoring.request(for: manifest.testSuites[0], in: manifest)
        let anchor = NotebookTestAnchoring.resolve(request, solution: try solution)
        #expect(anchor == NotebookAnchor(kind: .section, name: "Task 4: Plot the week", rule: .section))
        #expect(anchor.cellIndex(in: try solution) == 6)
    }

    @Test func aFamilyAnchorsToItsFunction() throws {
        let family = PatternFamily(
            id: "fam", name: "Counts", kind: .boundaryEquality, functionName: "count_active_days",
            paramNames: ["steps", "goal"])
        let manifest = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "test_fam_a.py", generatedBy: "fam")],
            language: .python, testItems: [.family(family)])
        let anchor = NotebookTestAnchoring.resolve(
            NotebookTestAnchoring.request(for: manifest.testSuites[0], in: manifest), solution: try solution)
        #expect(anchor == NotebookAnchor(kind: .name, name: "count_active_days", rule: .family))
    }

    @Test func aVariableEqualityCaseAnchorsToItsVariable() throws {
        let family = PatternFamily(
            id: "vars", name: "Values", kind: .variableEquality, functionName: "",
            cases: [
                PatternCase(key: "goal", label: "goal", args: [.string("GOAL")], expected: .int(8000)),
                PatternCase(key: "sum", label: "summary", args: [.string("summary")], expected: .int(0)),
            ])
        let manifest = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "test_vars_sum.py", generatedBy: "vars")],
            language: .python, testItems: [.family(family)])
        let anchor = NotebookTestAnchoring.resolve(
            NotebookTestAnchoring.request(for: manifest.testSuites[0], in: manifest), solution: try solution)
        #expect(anchor == NotebookAnchor(kind: .name, name: "summary", rule: .family))
    }

    @Test func aScriptWithOneDefinedNameAnchorsToIt() throws {
        let request = NotebookAnchorRequest(
            scriptSource: "from student_module import *\nassert student_module.count_active_days([1], 0) == 1")
        let anchor = NotebookTestAnchoring.resolve(request, solution: try solution)
        #expect(anchor == NotebookAnchor(kind: .name, name: "count_active_days", rule: .script))
    }

    @Test func aScriptWithSeveralDefinedNamesTakesTheFirstInTheNotebookAndSaysSo() throws {
        let request = NotebookAnchorRequest(scriptSource: "assert summary == average_heart_rate([]) and GOAL > 0")
        let anchor = NotebookTestAnchoring.resolve(request, solution: try solution)
        #expect(anchor == NotebookAnchor(kind: .name, name: "GOAL", rule: .script, ambiguous: true))
    }

    @Test func aScriptWithNoDefinedNameFallsBackToItsSection() throws {
        let request = NotebookAnchorRequest(scriptSource: "assert True", sectionName: "Task 1: Count active days")
        let anchor = NotebookTestAnchoring.resolve(request, solution: try solution)
        #expect(anchor == NotebookAnchor(kind: .section, name: "Task 1: Count active days", rule: .section))
        #expect(anchor.cellIndex(in: try solution) == 2)
    }

    @Test func nothingToGoOnIsUnlinked() throws {
        let anchor = NotebookTestAnchoring.resolve(
            NotebookAnchorRequest(scriptSource: "assert True", sectionName: "No such heading"), solution: try solution)
        #expect(anchor == .unlinked)
        #expect(anchor.cellIndex(in: try solution) == nil)
    }

    @Test func anAnchorResolvesByNameInAnotherNotebook() throws {
        let anchor = NotebookAnchor(kind: .name, name: "average_heart_rate", rule: .check)
        let renamed = scanNotebookDefinitions(
            try notebook([.code("def avg_hr(readings):\n    return 0")]), language: .python)
        let moved = scanNotebookDefinitions(
            try notebook([.markdown("intro"), .code("x = 1"), .code("def average_heart_rate(r):\n    pass")]),
            language: .python)
        #expect(anchor.cellIndex(in: renamed) == nil)
        #expect(anchor.cellIndex(in: moved) == 2)
    }
}
