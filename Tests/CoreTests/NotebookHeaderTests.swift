// Tests/CoreTests/NotebookHeaderTests.swift
//
// `NotebookHeader` replaced `JSONSerialization` + `as?` casts at four
// notebook read sites. These tests pin the lenient semantics of those casts: a
// field of the wrong type reads as absent, and only a document that is not a
// JSON object fails the whole read. They also pin the three documented
// differences from `JSONSerialization`, so that a change to any of them is a
// decision and not an accident.

import Foundation
import Testing

@testable import Core

@Suite struct NotebookHeaderTests {

    private func header(_ json: String) -> NotebookHeader? {
        NotebookHeader(data: Data(json.utf8))
    }

    @Test func readsKernelNamesAndNBFormat() throws {
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
    }

    @Test(arguments: ["[]", "[{\"metadata\": {}}]", "42", "\"notebook\"", "null", "", "{not json"])
    func inputThatIsNotAJSONObjectIsNil(_ json: String) {
        #expect(header(json) == nil)
    }

    @Test func anEmptyObjectHasNoFields() throws {
        let read = try #require(header("{}"))
        #expect(read.metadata == nil)
        #expect(!read.hasNBFormatKey)
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

    /// A UTF-16 notebook reads the same as a UTF-8 one.
    @Test func utf16InputIsRead() throws {
        let json = "{\"metadata\": {\"kernelspec\": {\"name\": \"xlua\"}}}"
        let data = try #require(json.data(using: .utf16))
        #expect(NotebookHeader(data: data)?.metadata?.kernelName == "xlua")
    }

    /// Difference 1: the parts that the decoder skips are not checked. A raw
    /// newline inside a cell string is invalid JSON, and `JSONSerialization`
    /// rejects the whole document, but the header still reads. A validity
    /// gate must not use `NotebookHeader`.
    @Test func invalidJSONInASkippedPartStillHasAHeader() throws {
        let json = "{\"nbformat\": 4, \"cells\": [{\"source\": \"a\nb\"}]}"
        #expect((try? JSONSerialization.jsonObject(with: Data(json.utf8))) == nil)
        #expect(try #require(header(json)).hasNBFormatKey)
    }

    /// Difference 2: UTF-32 input with a byte-order mark is not read.
    @Test func utf32InputWithAByteOrderMarkIsNotRead() throws {
        let data = try #require("{\"nbformat\": 4}".data(using: .utf32))
        #expect(NotebookHeader(data: data) == nil)
    }

    /// Difference 3: when a key appears twice, the first value wins.
    /// `JSONSerialization` keeps the last one.
    @Test func theFirstOfTwoDuplicateKeysWins() throws {
        let json = """
            {"metadata": {"kernelspec": {"name": "xr"}},
             "metadata": {"kernelspec": {"name": "xlua"}}}
            """
        #expect(try #require(header(json)).metadata?.kernelName == "xr")
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
