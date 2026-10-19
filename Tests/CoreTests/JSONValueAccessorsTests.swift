// Tests/CoreTests/JSONValueAccessorsTests.swift
//
// The `JSONValue` accessors replace `as?` casts on `JSONSerialization` output
// in the worker's notebook path. These tests pin that each one matches the
// cast it replaced, most of all `arrayOfObjects`, which fails for the whole
// array when one element is not an object, as `as? [[String: Any]]` does.

import Foundation
import Testing

@testable import Core

@Suite struct JSONValueAccessorsTests {

    @Test func eachAccessorReadsOnlyItsOwnType() {
        let string = JSONValue.string("s")
        let array = JSONValue.array([.int(1)])
        let object = JSONValue.object(["k": .null])

        #expect(string.stringValue == "s")
        #expect(array.stringValue == nil)
        #expect(array.arrayValue == [.int(1)])
        #expect(object.arrayValue == nil)
        #expect(object.objectValue == ["k": .null])
        #expect(string.objectValue == nil)
    }

    @Test func theSubscriptReadsAMemberOfAnObjectOnly() {
        let object = JSONValue.object(["kernelspec": .object(["name": .string("xr")])])
        #expect(object["kernelspec"]?["name"] == .string("xr"))
        #expect(object["missing"] == nil)
        #expect(JSONValue.array([.string("kernelspec")])["kernelspec"] == nil)
    }

    /// A member whose value is `null` is present. `JSONSerialization` gave
    /// `NSNull` there, so `object["metadata"] != nil` was true.
    @Test func aNullMemberIsPresent() {
        #expect(JSONValue.object(["metadata": .null])["metadata"] != nil)
    }

    @Test func arrayOfObjectsNeedsEveryElementToBeAnObject() {
        let objects = JSONValue.array([.object(["a": .int(1)]), .object([:])])
        #expect(objects.arrayOfObjects == [["a": .int(1)], [:]])
        #expect(JSONValue.array([]).arrayOfObjects?.isEmpty == true)
        #expect(JSONValue.array([.object([:]), .string("cell")]).arrayOfObjects == nil)
        #expect(JSONValue.object([:]).arrayOfObjects == nil)
    }

    @Test func objectFromDataReadsATopLevelObject() throws {
        let object = try #require(JSONValue.object(from: Data("{\"nbformat\": 4, \"cells\": []}".utf8)))
        #expect(object == ["nbformat": .int(4), "cells": .array([])])
    }

    @Test(arguments: ["[]", "42", "\"notebook\"", "null", "", "{not json"])
    func objectFromDataIsNilForAnythingButAnObject(_ json: String) {
        #expect(JSONValue.object(from: Data(json.utf8)) == nil)
    }

    /// Every value is decoded, so invalid JSON deep in the document gives nil,
    /// as `JSONSerialization` does. This is what lets the worker's notebook
    /// validation use it.
    @Test func objectFromDataIsNilForInvalidJSONInANestedValue() {
        let rawNewline = "{\"cells\": [{\"source\": \"a\nb\"}]}"
        #expect((try? JSONSerialization.jsonObject(with: Data(rawNewline.utf8))) == nil)
        #expect(JSONValue.object(from: Data(rawNewline.utf8)) == nil)
    }

    /// Documented difference: the first of two duplicate keys wins.
    @Test func objectFromDataKeepsTheFirstOfTwoDuplicateKeys() throws {
        let object = try #require(JSONValue.object(from: Data("{\"k\": 1, \"k\": 2}".utf8)))
        #expect(object["k"] == .int(1))
    }

    // MARK: - Notebook helpers over JSONValue

    @Test func cellSourceReadsAStringOrAnArrayOfStrings() {
        #expect(NotebookCellSources.cellSource(["source": .string("x = 1")]) == "x = 1")
        #expect(
            NotebookCellSources.cellSource(["source": .array([.string("x = 1\n"), .string("y = 2")])])
                == "x = 1\ny = 2")
    }

    /// The array form counts only when every element is a string, the same as
    /// `as? [String]`, and anything else reads as an empty source.
    @Test func cellSourceIsEmptyForAnythingElse() {
        #expect(NotebookCellSources.cellSource(["source": .array([.string("x"), .int(1)])]).isEmpty)
        #expect(NotebookCellSources.cellSource(["source": .int(1)]).isEmpty)
        #expect(NotebookCellSources.cellSource([:]).isEmpty)
    }

    @Test func metadataReadsKernelNamesFromAParsedObject() {
        let metadata = NotebookHeader.Metadata([
            "kernelspec": .object(["name": .string("xoctave")]),
            "language_info": .object(["name": .int(3)]),
        ])
        #expect(metadata == NotebookHeader.Metadata(kernelName: "xoctave", languageInfoName: nil))
        #expect(AssignmentLanguage.fromNotebookMetadata(metadata) == .octave)
    }
}
