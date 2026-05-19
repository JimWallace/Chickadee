// Tests/APITests/GlobalInputsTests.swift
//
// Slice 1 of issue #461 — unit-level coverage for the new pieces:
//   - TestScriptVariablePrepender (raw-script inlining + idempotent re-prepend)
//   - NotebookSubstitution (cell-source rewrites, fenced metadata,
//     placeholder discovery)
//   - TestProperties.globalVariables decode round-trip
//
// Endpoint integration / route-level tests stay in the route test files;
// these focus on the building blocks.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct GlobalInputsTests {

    // MARK: - TestScriptVariablePrepender

    @Test func prepender_emit_emptyListYieldsEmptyString() {
        #expect(TestScriptVariablePrepender.emit([]).isEmpty)
    }

    @Test func prepender_emit_singleVariable() {
        let vars = [FamilyVariable(name: "x", value: .int(12))]
        #expect(TestScriptVariablePrepender.emit(vars) == "x = 12")
    }

    @Test func prepender_emit_multipleVariablesInOrder() {
        let vars = [
            FamilyVariable(name: "x", value: .int(1)),
            FamilyVariable(name: "y", value: .string("hi")),
        ]
        #expect(TestScriptVariablePrepender.emit(vars) == "x = 1\ny = \"hi\"")
    }

    @Test func prepender_emitBlock_emptyYieldsEmpty() {
        #expect(TestScriptVariablePrepender.emitBlock([]).isEmpty)
    }

    @Test func prepender_emitBlock_addsTrailingBlankLine() {
        let vars = [FamilyVariable(name: "x", value: .int(1))]
        #expect(TestScriptVariablePrepender.emitBlock(vars) == "x = 1\n\n")
    }

    @Test func prepender_prependToRawScript_emptyVariablesReturnsBodyUnchanged() {
        let body = "import os\nprint('hi')\n"
        #expect(TestScriptVariablePrepender.prependToRawScript(body, variables: []) == body)
    }

    @Test func prepender_prependToRawScript_addsBannerAndDecls() {
        let body = "import os\nprint('hi')\n"
        let result = TestScriptVariablePrepender.prependToRawScript(
            body,
            variables: [FamilyVariable(name: "x", value: .int(7))]
        )
        #expect(result.contains(TestScriptVariablePrepender.rawScriptBannerComment))
        #expect(result.contains("x = 7"))
        #expect(result.contains("import os"))
        // Banner appears before the original body.
        if let bannerRange = result.range(of: TestScriptVariablePrepender.rawScriptBannerComment),
            let importRange = result.range(of: "import os")
        {
            #expect(bannerRange.upperBound < importRange.lowerBound)
        } else {
            Issue.record("Banner or import line not found")
        }
    }

    @Test func prepender_prependToRawScript_preservesShebang() {
        let body = "#!/usr/bin/env python3\nimport os\n"
        let result = TestScriptVariablePrepender.prependToRawScript(
            body,
            variables: [FamilyVariable(name: "x", value: .int(1))]
        )
        // Shebang must stay on line 1.
        let firstLine = result.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        #expect(firstLine == "#!/usr/bin/env python3")
        #expect(result.contains("x = 1"))
    }

    @Test func prepender_idempotentReSave() {
        // Save once with x=1, then re-save with x=2.  Result should have
        // exactly one block carrying the new value.
        let body = "import os\nprint('hi')\n"
        let firstPass = TestScriptVariablePrepender.prependToRawScript(
            body,
            variables: [FamilyVariable(name: "x", value: .int(1))]
        )
        let secondPass = TestScriptVariablePrepender.prependToRawScript(
            firstPass,
            variables: [FamilyVariable(name: "x", value: .int(2))]
        )
        // Old value gone, new value present, banner appears once.
        #expect(secondPass.contains("x = 1") == false)
        #expect(secondPass.contains("x = 2"))
        let bannerOccurrences =
            secondPass.components(
                separatedBy: TestScriptVariablePrepender.rawScriptBannerComment
            ).count - 1
        #expect(bannerOccurrences == 1, "banner should appear exactly once after re-prepending")
    }

    @Test func prepender_emptyVariablesStripsExistingBlock() {
        let body = "import os\nprint('hi')\n"
        let prepended = TestScriptVariablePrepender.prependToRawScript(
            body,
            variables: [FamilyVariable(name: "x", value: .int(1))]
        )
        // Caller decides there are no inputs anymore — block should be removed.
        let stripped = TestScriptVariablePrepender.prependToRawScript(
            prepended,
            variables: []
        )
        #expect(stripped.contains(TestScriptVariablePrepender.rawScriptBannerComment) == false)
        #expect(stripped.contains("x = 1") == false)
        #expect(stripped.contains("import os"))
    }

    @Test func prepender_applyForRawScript_skipsNonPython() {
        let manifest = TestProperties(globalVariables: [
            FamilyVariable(name: "x", value: .int(1))
        ])
        let body = "echo hi"
        let result = TestScriptVariablePrepender.applyForRawScript(
            filename: "test.sh",
            content: body,
            manifest: manifest
        )
        #expect(result == body)
    }

    @Test func prepender_applyForRawScript_combinesGlobalAndSection() {
        let section = TestSuiteSection(
            id: "sec1", name: "Q1",
            variables: [FamilyVariable(name: "s", value: .int(99))]
        )
        let entry = TestSuiteEntry(tier: .pub, script: "t.py", sectionID: "sec1")
        let manifest = TestProperties(
            testSuites: [entry],
            sections: [section],
            globalVariables: [FamilyVariable(name: "g", value: .int(7))]
        )
        let result = TestScriptVariablePrepender.applyForRawScript(
            filename: "t.py",
            content: "print('hi')",
            manifest: manifest
        )
        #expect(result.contains("g = 7"))
        #expect(result.contains("s = 99"))
        // Global appears before section (broader scope first).
        if let g = result.range(of: "g = 7"),
            let s = result.range(of: "s = 99")
        {
            #expect(g.lowerBound < s.lowerBound)
        }
    }

    // MARK: - NotebookSubstitution

    private func minimalNotebook(cellSources: [String]) throws -> Data {
        let cells: [[String: Any]] = cellSources.map { src in
            [
                "cell_type": "code",
                "source": src,
                "metadata": [String: Any](),
                "execution_count": NSNull(),
                "outputs": [Any](),
            ]
        }
        let nb: [String: Any] = [
            "cells": cells,
            "metadata": ["kernelspec": ["name": "python3", "display_name": "Python 3"]],
            "nbformat": 4,
            "nbformat_minor": 5,
        ]
        return try JSONSerialization.data(withJSONObject: nb)
    }

    @Test func substitution_replacesPlaceholderInCodeCell() throws {
        // Instructor writes `ciphertext = {{ciphertext}}` (no quotes
        // around the marker — the substituted value IS a Python literal,
        // i.e. `repr("Khoor")` = `'"Khoor"'`).  Mirrors the design doc's
        // contract: substitution drops a `repr()` directly into Python
        // source.
        let data = try minimalNotebook(cellSources: ["ciphertext = {{ciphertext}}"])
        let result = try NotebookSubstitution.apply(
            notebookData: data,
            substitutions: ["ciphertext": "\"Khoor\""],
            strict: true
        )
        guard let nb = try JSONSerialization.jsonObject(with: result) as? [String: Any],
            let cells = nb["cells"] as? [[String: Any]],
            let source = cells.first?["source"] as? String
        else {
            Issue.record("Unexpected notebook shape")
            return
        }
        #expect(source == "ciphertext = \"Khoor\"")
    }

    @Test func substitution_tagsRewrittenCellWithFencedMetadata() throws {
        let data = try minimalNotebook(cellSources: ["x = \"{{name}}\""])
        let result = try NotebookSubstitution.apply(
            notebookData: data,
            substitutions: ["name": "\"Alice\""],
            strict: false
        )
        guard let nb = try JSONSerialization.jsonObject(with: result) as? [String: Any],
            let cells = nb["cells"] as? [[String: Any]],
            let metadata = cells.first?["metadata"] as? [String: Any]
        else {
            Issue.record("Unexpected notebook shape")
            return
        }
        #expect(metadata[NotebookSubstitution.fencedCellMetadataKey] as? String == "name")
    }

    @Test func substitution_strictThrowsOnUnknown() throws {
        let data = try minimalNotebook(cellSources: ["x = \"{{nope}}\""])
        #expect {
            try NotebookSubstitution.apply(
                notebookData: data,
                substitutions: [:],
                strict: true
            )
        } throws: { error in
            if case NotebookSubstitutionError.unknownPlaceholder(let name) = error {
                return name == "nope"
            }
            return false
        }
    }

    @Test func substitution_nonStrictLeavesUnknownAlone() throws {
        let data = try minimalNotebook(cellSources: ["x = \"{{nope}}\""])
        let result = try NotebookSubstitution.apply(
            notebookData: data,
            substitutions: [:],
            strict: false
        )
        guard let nb = try JSONSerialization.jsonObject(with: result) as? [String: Any],
            let cells = nb["cells"] as? [[String: Any]],
            let source = cells.first?["source"] as? String
        else {
            Issue.record("Unexpected notebook shape")
            return
        }
        #expect(source == "x = \"{{nope}}\"")
    }

    @Test func substitution_skipsMarkdownCells() throws {
        // Build a notebook with a markdown cell containing {{name}}.
        let nb: [String: Any] = [
            "cells": [
                [
                    "cell_type": "markdown",
                    "source": "Welcome {{name}}",
                    "metadata": [String: Any](),
                ]
            ],
            "metadata": [:],
            "nbformat": 4,
            "nbformat_minor": 5,
        ]
        let data = try JSONSerialization.data(withJSONObject: nb)
        let result = try NotebookSubstitution.apply(
            notebookData: data,
            substitutions: ["name": "\"Alice\""],
            strict: true
        )
        guard let nb2 = try JSONSerialization.jsonObject(with: result) as? [String: Any],
            let cells = nb2["cells"] as? [[String: Any]],
            let source = cells.first?["source"] as? String
        else {
            Issue.record("Unexpected notebook shape")
            return
        }
        #expect(source == "Welcome {{name}}")
    }

    @Test func substitution_placeholderNamesReturnsSortedDedupedNames() throws {
        let data = try minimalNotebook(cellSources: [
            "a = \"{{name}}\"",
            "b = {{shift}} + {{name}}",
        ])
        #expect(NotebookSubstitution.placeholderNames(in: data) == ["name", "shift"])
    }

    @Test func substitution_multiplePlaceholdersInOneCell() throws {
        let data = try minimalNotebook(cellSources: ["pair = ({{a}}, {{b}})"])
        let result = try NotebookSubstitution.apply(
            notebookData: data,
            substitutions: ["a": "1", "b": "2"],
            strict: true
        )
        guard let nb = try JSONSerialization.jsonObject(with: result) as? [String: Any],
            let cells = nb["cells"] as? [[String: Any]],
            let source = cells.first?["source"] as? String
        else {
            Issue.record("Unexpected notebook shape")
            return
        }
        #expect(source == "pair = (1, 2)")
    }

    @Test func substitution_arrayShapeSourcePreserved() throws {
        // nbformat's source-as-array shape: ["line1\n", "line2"].
        let nb: [String: Any] = [
            "cells": [
                [
                    "cell_type": "code",
                    "source": ["x = \"{{name}}\"\n", "y = 1"],
                    "metadata": [String: Any](),
                ]
            ],
            "metadata": [:],
            "nbformat": 4,
            "nbformat_minor": 5,
        ]
        let data = try JSONSerialization.data(withJSONObject: nb)
        let result = try NotebookSubstitution.apply(
            notebookData: data,
            substitutions: ["name": "\"Alice\""],
            strict: true
        )
        guard let nb2 = try JSONSerialization.jsonObject(with: result) as? [String: Any],
            let cells = nb2["cells"] as? [[String: Any]],
            let source = cells.first?["source"] as? [String]
        else {
            Issue.record("Expected array source shape preserved")
            return
        }
        // Source should still be an array, with substitution applied.
        #expect(source.joined().contains("Alice"))
    }

    // MARK: - TestProperties.globalVariables round-trip

    @Test func testProperties_globalVariablesRoundTrip() throws {
        let props = TestProperties(
            globalVariables: [
                FamilyVariable(name: "quotes", value: .array([.string("hi"), .string("hi")])),
                FamilyVariable(name: "n", value: .int(42)),
            ]
        )
        let data = try JSONEncoder().encode(props)
        let decoded = try JSONDecoder().decode(TestProperties.self, from: data)
        #expect(decoded.globalVariables.count == 2)
        #expect(decoded.globalVariables[0].name == "quotes")
        #expect(decoded.globalVariables[1].name == "n")
    }

    @Test func testProperties_missingGlobalVariablesDecodesAsEmpty() throws {
        let json = Data(
            #"""
            {"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}
            """#.utf8)
        let decoded = try JSONDecoder().decode(TestProperties.self, from: json)
        #expect(decoded.globalVariables.isEmpty)
    }

    @Test func testProperties_runnerSanitizedPreservesGlobalVariables() {
        let props = TestProperties(
            globalVariables: [FamilyVariable(name: "x", value: .int(1))]
        )
        let sanitized = props.runnerSanitized()
        #expect(sanitized.globalVariables.count == 1)
        #expect(sanitized.globalVariables[0].name == "x")
    }
}
