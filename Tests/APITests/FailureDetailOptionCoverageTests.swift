// Tests/APITests/FailureDetailOptionCoverageTests.swift
//
// The two hand-written option lists in the browser editors — the family
// editor's default select in `_family-editor-body.leaf` and the script
// editor's `FAILURE_DETAIL_OPTIONS` — must offer exactly the non-default
// `FailureDetail` cases. A level added to the enum without an option here
// would be settable only through MCP; an option here the enum lacks would be
// refused on save.

import Core
import Foundation
import Testing

@Suite struct FailureDetailOptionCoverageTests {

    private var expectedTokens: Set<String> {
        Set(FailureDetail.allCases.filter { $0 != .full }.map(\.rawValue))
    }

    private func tokens(in text: String, pattern: String) throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return Set(
            regex.matches(in: text, range: range).compactMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]) }
            }.filter { !$0.isEmpty })
    }

    @Test func familyEditorSelectOffersEveryNonDefaultLevel() throws {
        let leaf = try String(contentsOfFile: "Resources/Views/_family-editor-body.leaf", encoding: .utf8)
        guard let start = leaf.range(of: "id=\"family-default-failure-detail\""),
            let end = leaf.range(of: "</select>", range: start.upperBound..<leaf.endIndex)
        else {
            Issue.record("the family editor has no failure-detail select")
            return
        }
        let block = String(leaf[start.lowerBound..<end.lowerBound])
        #expect(try tokens(in: block, pattern: #"<option value="([A-Za-z]*)""#) == expectedTokens)
    }

    @Test func scriptEditorOptionsOfferEveryNonDefaultLevel() throws {
        let js = try String(contentsOfFile: "Public/test-renderer-script.js", encoding: .utf8)
        guard let start = js.range(of: "var FAILURE_DETAIL_OPTIONS = ["),
            let end = js.range(of: "];", range: start.upperBound..<js.endIndex)
        else {
            Issue.record("the script editor has no FAILURE_DETAIL_OPTIONS list")
            return
        }
        let block = String(js[start.lowerBound..<end.lowerBound])
        #expect(try tokens(in: block, pattern: #"value: '([A-Za-z]*)'"#) == expectedTokens)
    }
}
