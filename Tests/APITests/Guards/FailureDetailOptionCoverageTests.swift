// Tests/APITests/Guards/FailureDetailOptionCoverageTests.swift
//
// The two hand-written option lists in the browser editors — the family
// editor's default select in `FamilyEditorBody` (read from its render) and the script
// editor's `FAILURE_DETAIL_OPTIONS` — must offer exactly the non-default
// `FailureDetail` cases. A level added to the enum without an option here
// would be settable only through MCP; an option here the enum lacks would be
// refused on save.

import Core
import Elementary
import Foundation
import Testing

@testable import APIServer

@Suite struct FailureDetailOptionCoverageTests {

    private var expectedTokens: Set<String> {
        Set(FailureDetail.allCases.filter { $0 != .full }.map(\.rawValue))
    }

    private func tokens(in text: String, pattern: String) throws -> Set<String> {
        let regex = try Regex(pattern)
        return Set(
            text.matches(of: regex).compactMap { match in
                match.output.count > 1 ? match.output[1].substring.map(String.init) : nil
            }.filter { !$0.isEmpty })
    }

    @Test func familyEditorSelectOffersEveryNonDefaultLevel() throws {
        let html = FamilyEditorBody().render()
        let start = try #require(
            html.range(of: "id=\"family-default-failure-detail\""), "the family editor has no failure-detail select")
        let end = try #require(
            html.range(of: "</select>", range: start.upperBound..<html.endIndex),
            "the family editor's failure-detail select is never closed")
        let block = String(html[start.lowerBound..<end.lowerBound])
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
