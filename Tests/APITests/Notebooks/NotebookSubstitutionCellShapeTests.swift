// Tests/APITests/Notebooks/NotebookSubstitutionCellShapeTests.swift
//
// `NotebookSubstitution.apply` writes a cell back only when it substituted
// something, and keeps the shape of the cell's `source`. A mutation run on
// the personalization substitution files (2026-11-14) found two mutants that
// no suite could detect:
//
// - `rewritten != originalSource` flipped to `==`, which rewrites and fences
//   EVERY code cell, also a cell with no placeholder;
// - `i == parts.count - 1` flipped to `!=` in `splitSourceForArrayShape`,
//   which moves each newline to the wrong line of an array-shaped source.

import Foundation
import Testing

@testable import APIServer

@Suite struct NotebookSubstitutionCellShapeTests {

    private func notebook(cells: [[String: Any]]) throws -> Data {
        let json: [String: Any] = [
            "cells": cells, "metadata": [String: Any](), "nbformat": 4, "nbformat_minor": 5,
        ]
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func codeCell(_ source: Any) -> [String: Any] {
        ["cell_type": "code", "metadata": [String: Any](), "source": source, "outputs": [Any]()]
    }

    private func cells(_ data: Data) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(object?["cells"] as? [[String: Any]])
    }

    private func fence(_ cell: [String: Any]) -> String? {
        (cell["metadata"] as? [String: Any])?[NotebookSubstitution.fencedCellMetadataKey] as? String
    }

    @Test func aCodeCellWithoutPlaceholdersIsNotFenced() throws {
        let data = try notebook(cells: [codeCell("x = {{rows}}"), codeCell("print(x)")])
        let result = try cells(
            NotebookSubstitution.apply(notebookData: data, substitutions: ["rows": "3"]))
        #expect(result.count == 2)
        #expect(fence(result[0]) == "rows")
        #expect(fence(result[1]) == nil)
        #expect(result[1]["source"] as? String == "print(x)")
    }

    @Test func anArrayShapedSourceKeepsEachNewlineOnItsOwnLine() throws {
        let data = try notebook(cells: [codeCell(["x = {{rows}}\n", "y = x\n", "print(y)"])])
        let result = try cells(
            NotebookSubstitution.apply(notebookData: data, substitutions: ["rows": "3"]))
        let source = try #require(result.first?["source"] as? [String])
        #expect(source == ["x = 3\n", "y = x\n", "print(y)"])
    }

    @Test func anArrayShapedSourceWithATrailingNewlineHasNoEmptyLastLine() throws {
        let data = try notebook(cells: [codeCell(["x = {{rows}}\n"])])
        let result = try cells(
            NotebookSubstitution.apply(notebookData: data, substitutions: ["rows": "3"]))
        let source = try #require(result.first?["source"] as? [String])
        #expect(source == ["x = 3\n"])
    }
}
