// Tests/APITests/Notebooks/FilterNotebookHiddenTierTests.swift
//
// `filterNotebook` removes the test cells of hidden tiers before a notebook is
// served to a student. A test cell names its tier on its first line, for
// example `# TEST: tier=secret`. A test cell that names no tier is public by
// default, so it must stay. That branch had no test. These tests also pin
// which cells are removed and that bytes that are not a notebook are returned
// unchanged.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct FilterNotebookHiddenTierTests {

    private func notebook(_ sources: [String]) -> Data {
        let cells = sources.map { source -> JSONValue in
            .object([
                "cell_type": .string("code"),
                "source": .string(source),
                "metadata": .object([:]),
                "outputs": .array([]),
            ])
        }
        let root: [String: JSONValue] = [
            "cells": .array(cells),
            "metadata": .object([:]),
            "nbformat": .int(4),
            "nbformat_minor": .int(5),
        ]
        return JSONValue.data(fromObject: root) ?? Data()
    }

    private func sources(_ data: Data) throws -> [String] {
        let root = try #require(JSONValue.object(from: data))
        let cells = try #require(root["cells"]?.arrayOfObjects)
        return cells.map(NotebookCellSources.cellSource)
    }

    @Test func aTestCellWithNoTierIsPublicAndStays() throws {
        let input = notebook([
            "x = 1",
            "# TEST: check_x\nassert x == 1",
            "# TEST: tier=secret\nassert x > 0",
        ])
        let kept = try sources(filterNotebook(input, hiddenTiers: ["secret", "release"]))
        #expect(kept == ["x = 1", "# TEST: check_x\nassert x == 1"])
    }

    @Test func onlyTheNamedHiddenTiersAreRemoved() throws {
        let input = notebook([
            "# TEST: tier=public\nassert True",
            "# TEST: tier=release\nassert True",
            "#TEST: tier=secret\nassert True",
        ])
        #expect(
            try sources(filterNotebook(input, hiddenTiers: ["secret"])) == [
                "# TEST: tier=public\nassert True", "# TEST: tier=release\nassert True",
            ])
        #expect(
            try sources(filterNotebook(input, hiddenTiers: ["secret", "release"])) == [
                "# TEST: tier=public\nassert True"
            ])
        #expect(try sources(filterNotebook(input, hiddenTiers: [])).count == 3)
    }

    @Test func aTierWordOutsideATestHeaderDoesNotHideACell() throws {
        // Only a first line that is a `# TEST:` header is read for a tier.
        let input = notebook([
            "\n\nx = 1  # tier=secret",
            "print('# TEST: tier=secret')",
        ])
        #expect(try sources(filterNotebook(input, hiddenTiers: ["secret"])).count == 2)
    }

    @Test func bytesThatAreNotANotebookAreReturnedUnchanged() {
        let notJSON = Data("not a notebook".utf8)
        #expect(filterNotebook(notJSON, hiddenTiers: ["secret"]) == notJSON)

        let noCells = Data(#"{"metadata":{}}"#.utf8)
        #expect(filterNotebook(noCells, hiddenTiers: ["secret"]) == noCells)
    }
}
