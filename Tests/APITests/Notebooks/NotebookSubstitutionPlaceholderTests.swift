// Tests/APITests/Notebooks/NotebookSubstitutionPlaceholderTests.swift
//
// `NotebookSubstitution` finds `{{name}}` placeholders with a Swift regex.
// These cases pin how it treats a cell with several placeholders, known and
// unknown, in strict and in non-strict mode.

import Foundation
import Testing

@testable import APIServer

@Suite struct NotebookSubstitutionPlaceholderTests {

    private func notebook(_ source: String) throws -> Data {
        let cell: [String: Any] = ["cell_type": "code", "metadata": [String: Any](), "source": source, "outputs": []]
        let json: [String: Any] = ["cells": [cell], "metadata": [String: Any](), "nbformat": 4, "nbformat_minor": 5]
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func firstCellSource(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let cells = try #require(object?["cells"] as? [[String: Any]])
        let source = try #require(cells.first?["source"])
        if let text = source as? String { return text }
        return try #require(source as? [String]).joined()
    }

    @Test func strictModeNamesTheLastUnknownPlaceholder() throws {
        let data = try notebook("a = {{first}}\nb = {{known}}\nc = {{second}}")
        #expect {
            try NotebookSubstitution.apply(notebookData: data, substitutions: ["known": "1"], strict: true)
        } throws: { error in
            if case NotebookSubstitutionError.unknownPlaceholder(let name) = error { return name == "second" }
            return false
        }
    }

    @Test func nonStrictModeReplacesKnownAndKeepsUnknownVerbatim() throws {
        let data = try notebook("a = {{first}}\nb = {{known}}\nc = {{second}}")
        let result = try NotebookSubstitution.apply(
            notebookData: data, substitutions: ["known": "42"], strict: false)
        #expect(try firstCellSource(result) == "a = {{first}}\nb = 42\nc = {{second}}")
    }

    @Test func aReplacedLiteralIsNotScannedAgain() throws {
        let data = try notebook("x = {{outer}}")
        let result = try NotebookSubstitution.apply(
            notebookData: data, substitutions: ["outer": "\"{{inner}}\""], strict: true)
        #expect(try firstCellSource(result) == "x = \"{{inner}}\"")
    }

    @Test func placeholderNamesAreDeduplicatedSortedAndSkipProse() {
        let source = "{{b}} {{a}} {{b}} {{ some prose }} {{c d}}"
        #expect(NotebookSubstitution.placeholderNames(inSource: source) == ["a", "b"])
    }
}
