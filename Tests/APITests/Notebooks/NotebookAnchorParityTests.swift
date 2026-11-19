// Tests/APITests/Notebooks/NotebookAnchorParityTests.swift
//
// The student guide and the staff suite outline place each public test on the
// same cell: both read anchors through `SuiteAnchorResolution`
// (docs/notebook-guide.md, "Anchors"). A pin, a notebook check's variable and a
// script test's solution name each give the same anchor on both surfaces.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct NotebookAnchorParityTests {

    private let manifest = TestProperties(
        testSuites: [
            TestSuiteEntry(tier: .pub, script: "check_c1.py", generatedByCheck: "c1", sectionID: "s1"),
            TestSuiteEntry(tier: .pub, script: "test_count.py", sectionID: "s1"),
            TestSuiteEntry(tier: .pub, script: "test_rate.py", sectionID: "s2", anchor: "summary"),
        ],
        language: .python,
        sections: [
            TestSuiteSection(id: "s1", name: "Task 1: Count"),
            TestSuiteSection(id: "s2", name: "Task 2: Rate"),
        ],
        testItems: [.check(NotebookCheck(id: "c1", kind: .variableExists, variable: "total"))])

    private let scripts = [
        "test_count.py": "assert count_days([1], 0) == 1",
        "test_rate.py": "assert rate([60]) == 60",
    ]

    private func solution() throws -> NotebookDefinitionScan {
        let cells: [[String: Any]] = [
            ["cell_type": "markdown", "metadata": [:], "source": "## Task 1: Count"],
            code("def count_days(steps, goal):\n    return 0"),
            code("total = 3"),
            ["cell_type": "markdown", "metadata": [:], "source": "## Task 2: Rate"],
            code("def rate(readings):\n    return 0"),
            code("summary = rate([60])"),
        ]
        let data = try JSONSerialization.data(withJSONObject: ["nbformat": 4, "nbformat_minor": 5, "cells": cells])
        return scanNotebookDefinitions(data, language: .python)
    }

    private func code(_ source: String) -> [String: Any] {
        ["cell_type": "code", "metadata": [:], "source": source, "outputs": [], "execution_count": NSNull()]
    }

    @Test func theGuideAndTheOutlineGiveEachTestTheSameCell() throws {
        let scan = try solution()
        let guide = NotebookGuideBuilder(
            manifest: manifest, solution: scan, starter: nil, scriptSources: scripts, attempt: nil
        ).build()
        let outline = InstructorSuiteOutlineBuilder(
            manifest: manifest, notebook: scan, scriptSources: scripts, validationStatus: nil, solutionRun: nil
        ).build()

        let guideCells = guide.tasks.map { Set($0.anchors.map { "\($0.kind):\($0.name)" }) }
        let outlineCells = outline.sections.filter { $0.id != nil }.map { section in
            Set(section.items.compactMap { $0.anchor.map { "\($0.kind):\($0.name)" } })
        }
        #expect(guideCells == outlineCells)
        #expect(guideCells == [["variable:total", "function:count_days"], ["variable:summary"]])
    }

    /// With no assignment row and no solution, the template starter decides
    /// the anchors: its section and its definitions, read raw.
    @Test func withNoSolutionTheTemplateStarterGivesTheScan() async throws {
        try await withWebRoutesApp { app in
            let setup = try await wrInsertSetup(id: "setup_parity", on: app)
            let path = app.testSetupsDirectory + "setup_parity.ipynb"
            let cells: [[String: Any]] = [
                ["cell_type": "markdown", "metadata": [:], "source": "## Task 1: Count {{n}}"],
                code("def count_days(steps, goal):\n    return 0"),
            ]
            try JSONSerialization.data(withJSONObject: ["nbformat": 4, "nbformat_minor": 5, "cells": cells])
                .write(to: URL(fileURLWithPath: path))
            setup.notebookPath = path
            try await setup.save(on: app.db)

            let scan = await SuiteAnchorResolution.notebookScan(
                assignment: nil, setup: setup, language: .python, db: app.db,
                testSetupsDirectory: app.testSetupsDirectory)
            #expect(scan.sections.map(\.name) == ["Task 1: Count {{n}}"], "the template, unsubstituted")
            #expect(scan.definition(of: "count_days") != nil)
        }
    }
}
