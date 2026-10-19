// Tests/CoreTests/NotebookHeaderTests.swift
//
// `NotebookHeader` replaced `JSONSerialization` + `as?` casts at five read
// sites. These tests pin the lenient semantics of those casts: a field of the
// wrong type reads as absent, and only a document that is not a JSON object
// fails the whole read.

import Foundation
import Testing

@testable import Core

@Suite struct NotebookHeaderTests {

    private func header(_ json: String) -> NotebookHeader? {
        NotebookHeader(data: Data(json.utf8))
    }

    @Test func readsKernelNamesCellCountAndNBFormat() throws {
        let read = try #require(
            header(
                """
                {"nbformat": 4,
                 "metadata": {"kernelspec": {"name": "xr", "display_name": "R"},
                              "language_info": {"name": "R"}},
                 "cells": [{"cell_type": "code", "source": "x <- 1"}, {"cell_type": "markdown"}]}
                """))
        #expect(read.metadata == NotebookHeader.Metadata(kernelName: "xr", languageInfoName: "R"))
        #expect(read.hasNBFormatKey)
        #expect(read.cellCount == 2)
    }

    @Test(arguments: ["[]", "[{\"metadata\": {}}]", "42", "\"notebook\"", "null", "", "{not json"])
    func inputThatIsNotAJSONObjectIsNil(_ json: String) {
        #expect(header(json) == nil)
    }

    @Test func anEmptyObjectHasNoFields() throws {
        let read = try #require(header("{}"))
        #expect(read.metadata == nil)
        #expect(!read.hasNBFormatKey)
        #expect(read.cellCount == nil)
    }

    /// `json["nbformat"] != nil` was true for a JSON `null`, because
    /// `JSONSerialization` gives `NSNull`. The key's presence is what counts.
    @Test func nbformatKeyCountsEvenWhenItsValueIsNull() throws {
        #expect(try #require(header("{\"nbformat\": null}")).hasNBFormatKey)
        #expect(try #require(header("{\"nbformat\": \"four\"}")).hasNBFormatKey)
    }

    @Test(arguments: ["{\"metadata\": 3}", "{\"metadata\": null}", "{\"metadata\": [\"kernelspec\"]}"])
    func metadataThatIsNotAnObjectIsNil(_ json: String) throws {
        #expect(try #require(header(json)).metadata == nil)
    }

    @Test func aMisTypedKernelFieldReadsAsAbsentAndKeepsTheOther() throws {
        let read = try #require(
            header(
                """
                {"metadata": {"kernelspec": {"name": 7},
                              "language_info": {"name": "lua"}}}
                """))
        #expect(read.metadata == NotebookHeader.Metadata(kernelName: nil, languageInfoName: "lua"))

        let notObject = try #require(header("{\"metadata\": {\"kernelspec\": \"python3\"}}"))
        #expect(notObject.metadata == NotebookHeader.Metadata(kernelName: nil, languageInfoName: nil))
    }

    /// The cells are counted, not decoded, so a cell of any JSON type counts.
    @Test func cellsOfAnyTypeAreCounted() throws {
        let read = try #require(header("{\"cells\": [1, null, \"s\", [2], {\"source\": [\"a\"]}]}"))
        #expect(read.cellCount == 5)
    }

    @Test(arguments: ["{\"cells\": {}}", "{\"cells\": null}", "{\"cells\": \"x\"}"])
    func cellsThatAreNotAnArrayHaveNoCount(_ json: String) throws {
        #expect(try #require(header(json)).cellCount == nil)
    }

    /// The sniff reads the header's names, so a notebook with a known kernel
    /// resolves and one with an unknown kernel does not.
    @Test func fromNotebookMetadataReadsTheHeader() throws {
        let r = try #require(header("{\"metadata\": {\"kernelspec\": {\"name\": \"xr\"}}}")?.metadata)
        #expect(AssignmentLanguage.fromNotebookMetadata(r) == .r)

        let unknown = try #require(header("{\"metadata\": {\"kernelspec\": {\"name\": \"cobol\"}}}")?.metadata)
        #expect(AssignmentLanguage.fromNotebookMetadata(unknown) == nil)
    }
}
