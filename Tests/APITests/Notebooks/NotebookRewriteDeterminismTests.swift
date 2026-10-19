// Tests/APITests/Notebooks/NotebookRewriteDeterminismTests.swift
//
// The notebook rewriters (`normalizeNotebookForJupyterLite`, `mergeNotebook`,
// `filterNotebook`, `NotebookSubstitution.apply`) write the bytes that are
// stored and that assignment versioning hashes. They encode through
// `JSONValue.data(fromObject:)`, which sorts keys, so the same document always
// gives the same bytes. With `JSONSerialization` the keys came out in
// dictionary order, so an unchanged notebook could hash differently from one
// save to the next.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct NotebookRewriteDeterminismTests {

    /// The same notebook with its keys in two orders.
    private let ordered = Data(
        #"{"cells":[{"cell_type":"code","metadata":{},"source":["x = 1\n"]}],"metadata":{"kernelspec":{"name":"python3"}},"nbformat":4,"nbformat_minor":5}"#
            .utf8)
    private let reordered = Data(
        #"{"nbformat_minor":5,"nbformat":4,"metadata":{"kernelspec":{"name":"python3"}},"cells":[{"source":["x = 1\n"],"metadata":{},"cell_type":"code"}]}"#
            .utf8)

    @Test func dataFromObjectSortsKeysAtEveryLevel() throws {
        let object: [String: JSONValue] = [
            "b": .int(1), "a": .object(["z": .null, "y": .array([.object(["d": .bool(true), "c": .string("s")])])]),
        ]
        let text = String(decoding: try #require(JSONValue.data(fromObject: object)), as: UTF8.self)
        #expect(text == #"{"a":{"y":[{"c":"s","d":true}],"z":null},"b":1}"#)
    }

    @Test func normalizingTheSameNotebookInAnyKeyOrderGivesTheSameBytes() {
        #expect(normalizeNotebookForJupyterLite(ordered) == normalizeNotebookForJupyterLite(reordered))
    }

    /// Normalizing an already-normalized notebook changes nothing, so a save
    /// with no edit stores the same bytes and the same version hash.
    @Test func normalizingIsIdempotent() {
        let once = normalizeNotebookForJupyterLite(ordered)
        #expect(normalizeNotebookForJupyterLite(once) == once)
    }

    @Test func mergingAndFilteringGiveTheSameBytesInAnyKeyOrder() {
        #expect(
            mergeNotebook(student: ordered, instructor: reordered)
                == mergeNotebook(student: reordered, instructor: ordered))
        #expect(filterNotebook(ordered, hiddenTiers: ["secret"]) == filterNotebook(reordered, hiddenTiers: ["secret"]))
    }

    @Test func substitutionGivesTheSameBytesInAnyKeyOrder() throws {
        func notebook(_ cell: String) -> Data {
            Data(#"{"cells":[\#(cell)],"metadata":{},"nbformat":4}"#.utf8)
        }
        let a = notebook(#"{"cell_type":"code","metadata":{},"source":["n = {{n}}\n"]}"#)
        let b = notebook(#"{"source":["n = {{n}}\n"],"metadata":{},"cell_type":"code"}"#)
        #expect(
            try NotebookSubstitution.apply(notebookData: a, substitutions: ["n": "3"])
                == NotebookSubstitution.apply(notebookData: b, substitutions: ["n": "3"]))
    }
}
