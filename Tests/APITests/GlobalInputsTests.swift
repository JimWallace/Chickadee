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

import XCTest
@testable import chickadee_server
import Core
import Foundation

final class GlobalInputsTests: XCTestCase {

    // MARK: - TestScriptVariablePrepender

    func testPrepender_emit_emptyListYieldsEmptyString() {
        XCTAssertEqual(TestScriptVariablePrepender.emit([]), "")
    }

    func testPrepender_emit_singleVariable() {
        let vars = [FamilyVariable(name: "x", value: .int(12))]
        XCTAssertEqual(TestScriptVariablePrepender.emit(vars), "x = 12")
    }

    func testPrepender_emit_multipleVariablesInOrder() {
        let vars = [
            FamilyVariable(name: "x", value: .int(1)),
            FamilyVariable(name: "y", value: .string("hi"))
        ]
        XCTAssertEqual(
            TestScriptVariablePrepender.emit(vars),
            "x = 1\ny = \"hi\""
        )
    }

    func testPrepender_emitBlock_emptyYieldsEmpty() {
        XCTAssertEqual(TestScriptVariablePrepender.emitBlock([]), "")
    }

    func testPrepender_emitBlock_addsTrailingBlankLine() {
        let vars = [FamilyVariable(name: "x", value: .int(1))]
        XCTAssertEqual(TestScriptVariablePrepender.emitBlock(vars), "x = 1\n\n")
    }

    func testPrepender_prependToRawScript_emptyVariablesReturnsBodyUnchanged() {
        let body = "import os\nprint('hi')\n"
        XCTAssertEqual(
            TestScriptVariablePrepender.prependToRawScript(body, variables: []),
            body
        )
    }

    func testPrepender_prependToRawScript_addsBannerAndDecls() {
        let body = "import os\nprint('hi')\n"
        let result = TestScriptVariablePrepender.prependToRawScript(
            body,
            variables: [FamilyVariable(name: "x", value: .int(7))]
        )
        XCTAssertTrue(result.contains(TestScriptVariablePrepender.rawScriptBannerComment))
        XCTAssertTrue(result.contains("x = 7"))
        XCTAssertTrue(result.contains("import os"))
        // Banner appears before the original body.
        if let bannerRange = result.range(of: TestScriptVariablePrepender.rawScriptBannerComment),
           let importRange = result.range(of: "import os") {
            XCTAssertLessThan(bannerRange.upperBound, importRange.lowerBound)
        } else {
            XCTFail("Banner or import line not found")
        }
    }

    func testPrepender_prependToRawScript_preservesShebang() {
        let body = "#!/usr/bin/env python3\nimport os\n"
        let result = TestScriptVariablePrepender.prependToRawScript(
            body,
            variables: [FamilyVariable(name: "x", value: .int(1))]
        )
        // Shebang must stay on line 1.
        let firstLine = result.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        XCTAssertEqual(firstLine, "#!/usr/bin/env python3")
        XCTAssertTrue(result.contains("x = 1"))
    }

    func testPrepender_idempotentReSave() {
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
        XCTAssertFalse(secondPass.contains("x = 1"))
        XCTAssertTrue(secondPass.contains("x = 2"))
        let bannerOccurrences = secondPass.components(
            separatedBy: TestScriptVariablePrepender.rawScriptBannerComment
        ).count - 1
        XCTAssertEqual(bannerOccurrences, 1, "banner should appear exactly once after re-prepending")
    }

    func testPrepender_emptyVariablesStripsExistingBlock() {
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
        XCTAssertFalse(stripped.contains(TestScriptVariablePrepender.rawScriptBannerComment))
        XCTAssertFalse(stripped.contains("x = 1"))
        XCTAssertTrue(stripped.contains("import os"))
    }

    func testPrepender_applyForRawScript_skipsNonPython() {
        let manifest = TestProperties(globalVariables: [
            FamilyVariable(name: "x", value: .int(1))
        ])
        let body = "echo hi"
        let result = TestScriptVariablePrepender.applyForRawScript(
            filename: "test.sh",
            content: body,
            manifest: manifest
        )
        XCTAssertEqual(result, body)
    }

    func testPrepender_applyForRawScript_combinesGlobalAndSection() {
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
        XCTAssertTrue(result.contains("g = 7"))
        XCTAssertTrue(result.contains("s = 99"))
        // Global appears before section (broader scope first).
        if let g = result.range(of: "g = 7"),
           let s = result.range(of: "s = 99") {
            XCTAssertLessThan(g.lowerBound, s.lowerBound)
        }
    }

    // MARK: - NotebookSubstitution

    private func minimalNotebook(cellSources: [String]) -> Data {
        let cells: [[String: Any]] = cellSources.map { src in
            [
                "cell_type": "code",
                "source": src,
                "metadata": [String: Any](),
                "execution_count": NSNull(),
                "outputs": [Any]()
            ]
        }
        let nb: [String: Any] = [
            "cells": cells,
            "metadata": ["kernelspec": ["name": "python3", "display_name": "Python 3"]],
            "nbformat": 4,
            "nbformat_minor": 5
        ]
        return try! JSONSerialization.data(withJSONObject: nb)
    }

    func testSubstitution_replacesPlaceholderInCodeCell() throws {
        // Instructor writes `ciphertext = {{ciphertext}}` (no quotes
        // around the marker — the substituted value IS a Python literal,
        // i.e. `repr("Khoor")` = `'"Khoor"'`).  Mirrors the design doc's
        // contract: substitution drops a `repr()` directly into Python
        // source.
        let data = minimalNotebook(cellSources: ["ciphertext = {{ciphertext}}"])
        let result = try NotebookSubstitution.apply(
            notebookData: data,
            substitutions: ["ciphertext": "\"Khoor\""],
            strict: true
        )
        guard let nb = try JSONSerialization.jsonObject(with: result) as? [String: Any],
              let cells = nb["cells"] as? [[String: Any]],
              let source = cells.first?["source"] as? String else {
            XCTFail("Unexpected notebook shape")
            return
        }
        XCTAssertEqual(source, "ciphertext = \"Khoor\"")
    }

    func testSubstitution_tagsRewrittenCellWithFencedMetadata() throws {
        let data = minimalNotebook(cellSources: ["x = \"{{name}}\""])
        let result = try NotebookSubstitution.apply(
            notebookData: data,
            substitutions: ["name": "\"Alice\""],
            strict: false
        )
        guard let nb = try JSONSerialization.jsonObject(with: result) as? [String: Any],
              let cells = nb["cells"] as? [[String: Any]],
              let metadata = cells.first?["metadata"] as? [String: Any] else {
            XCTFail("Unexpected notebook shape")
            return
        }
        XCTAssertEqual(
            metadata[NotebookSubstitution.fencedCellMetadataKey] as? String,
            "name"
        )
    }

    func testSubstitution_strictThrowsOnUnknown() {
        let data = minimalNotebook(cellSources: ["x = \"{{nope}}\""])
        XCTAssertThrowsError(try NotebookSubstitution.apply(
            notebookData: data,
            substitutions: [:],
            strict: true
        )) { error in
            if case NotebookSubstitutionError.unknownPlaceholder(let name) = error {
                XCTAssertEqual(name, "nope")
            } else {
                XCTFail("Expected unknownPlaceholder, got \(error)")
            }
        }
    }

    func testSubstitution_nonStrictLeavesUnknownAlone() throws {
        let data = minimalNotebook(cellSources: ["x = \"{{nope}}\""])
        let result = try NotebookSubstitution.apply(
            notebookData: data,
            substitutions: [:],
            strict: false
        )
        guard let nb = try JSONSerialization.jsonObject(with: result) as? [String: Any],
              let cells = nb["cells"] as? [[String: Any]],
              let source = cells.first?["source"] as? String else {
            XCTFail("Unexpected notebook shape")
            return
        }
        XCTAssertEqual(source, "x = \"{{nope}}\"")
    }

    func testSubstitution_skipsMarkdownCells() throws {
        // Build a notebook with a markdown cell containing {{name}}.
        let nb: [String: Any] = [
            "cells": [[
                "cell_type": "markdown",
                "source": "Welcome {{name}}",
                "metadata": [String: Any]()
            ]],
            "metadata": [:],
            "nbformat": 4,
            "nbformat_minor": 5
        ]
        let data = try JSONSerialization.data(withJSONObject: nb)
        let result = try NotebookSubstitution.apply(
            notebookData: data,
            substitutions: ["name": "\"Alice\""],
            strict: true
        )
        guard let nb2 = try JSONSerialization.jsonObject(with: result) as? [String: Any],
              let cells = nb2["cells"] as? [[String: Any]],
              let source = cells.first?["source"] as? String else {
            XCTFail("Unexpected notebook shape")
            return
        }
        XCTAssertEqual(source, "Welcome {{name}}")
    }

    func testSubstitution_placeholderNamesReturnsSortedDedupedNames() {
        let data = minimalNotebook(cellSources: [
            "a = \"{{name}}\"",
            "b = {{shift}} + {{name}}"
        ])
        XCTAssertEqual(NotebookSubstitution.placeholderNames(in: data), ["name", "shift"])
    }

    func testSubstitution_multiplePlaceholdersInOneCell() throws {
        let data = minimalNotebook(cellSources: ["pair = ({{a}}, {{b}})"])
        let result = try NotebookSubstitution.apply(
            notebookData: data,
            substitutions: ["a": "1", "b": "2"],
            strict: true
        )
        guard let nb = try JSONSerialization.jsonObject(with: result) as? [String: Any],
              let cells = nb["cells"] as? [[String: Any]],
              let source = cells.first?["source"] as? String else {
            XCTFail("Unexpected notebook shape")
            return
        }
        XCTAssertEqual(source, "pair = (1, 2)")
    }

    func testSubstitution_arrayShapeSourcePreserved() throws {
        // nbformat's source-as-array shape: ["line1\n", "line2"].
        let nb: [String: Any] = [
            "cells": [[
                "cell_type": "code",
                "source": ["x = \"{{name}}\"\n", "y = 1"],
                "metadata": [String: Any]()
            ]],
            "metadata": [:],
            "nbformat": 4,
            "nbformat_minor": 5
        ]
        let data = try JSONSerialization.data(withJSONObject: nb)
        let result = try NotebookSubstitution.apply(
            notebookData: data,
            substitutions: ["name": "\"Alice\""],
            strict: true
        )
        guard let nb2 = try JSONSerialization.jsonObject(with: result) as? [String: Any],
              let cells = nb2["cells"] as? [[String: Any]],
              let source = cells.first?["source"] as? [String] else {
            XCTFail("Expected array source shape preserved")
            return
        }
        // Source should still be an array, with substitution applied.
        XCTAssertTrue(source.joined().contains("Alice"))
    }

    // MARK: - TestProperties.globalVariables round-trip

    func testTestProperties_globalVariablesRoundTrip() throws {
        let props = TestProperties(
            globalVariables: [
                FamilyVariable(name: "quotes", value: .array([.string("hi"), .string("hi")])),
                FamilyVariable(name: "n", value: .int(42))
            ]
        )
        let data = try JSONEncoder().encode(props)
        let decoded = try JSONDecoder().decode(TestProperties.self, from: data)
        XCTAssertEqual(decoded.globalVariables.count, 2)
        XCTAssertEqual(decoded.globalVariables[0].name, "quotes")
        XCTAssertEqual(decoded.globalVariables[1].name, "n")
    }

    func testTestProperties_missingGlobalVariablesDecodesAsEmpty() throws {
        let json = #"""
        {"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TestProperties.self, from: json)
        XCTAssertEqual(decoded.globalVariables.count, 0)
    }

    func testTestProperties_runnerSanitizedPreservesGlobalVariables() {
        let props = TestProperties(
            globalVariables: [FamilyVariable(name: "x", value: .int(1))]
        )
        let sanitized = props.runnerSanitized()
        XCTAssertEqual(sanitized.globalVariables.count, 1)
        XCTAssertEqual(sanitized.globalVariables[0].name, "x")
    }
}
