// Tests/APITests/Notebooks/PandasEqualityIndexModeTests.swift
//
// The Python `data_frame_equality` and `series_equality` checks have two
// index modes. By default (`ignoreIndex` nil or true) both sides are reset to
// a fresh RangeIndex before the comparison, so a student who resets the index
// after a groupby still passes. With `ignoreIndex: false` the frames are
// compared as they are, so an assignment can grade the index. No other test
// rendered the second mode. These tests read the generated source.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct PandasEqualityIndexModeTests {

    private static let resetLines = [
        "actual_cmp = actual.reset_index(drop=True)",
        "expected_cmp = expected.reset_index(drop=True)",
    ]
    private static let asIsLines = ["actual_cmp = actual\n", "expected_cmp = expected\n"]

    private static func render(_ kind: NotebookCheckKind, ignoreIndex: Bool?) -> String {
        let check = NotebookCheck(
            id: "c", kind: kind, variable: "v", expectedCSV: "a\n1\n", ignoreIndex: ignoreIndex)
        switch kind {
        case .seriesEquality: return renderSeriesEquality(check, specHash: "h")
        default: return renderDataFrameEquality(check, specHash: "h")
        }
    }

    @Test(arguments: [NotebookCheckKind.dataFrameEquality, .seriesEquality])
    func theIndexIsResetByDefault(kind: NotebookCheckKind) {
        for ignoreIndex in [nil, true] as [Bool?] {
            let source = Self.render(kind, ignoreIndex: ignoreIndex)
            for line in Self.resetLines {
                #expect(source.contains(line), "\(kind) ignoreIndex=\(String(describing: ignoreIndex))")
            }
        }
    }

    @Test(arguments: [NotebookCheckKind.dataFrameEquality, .seriesEquality])
    func theIndexIsComparedAsIsWhenIgnoreIndexIsFalse(kind: NotebookCheckKind) {
        let source = Self.render(kind, ignoreIndex: false)
        for line in Self.asIsLines {
            #expect(source.contains(line))
        }
        #expect(!source.contains("reset_index(drop=True)"))
    }
}
