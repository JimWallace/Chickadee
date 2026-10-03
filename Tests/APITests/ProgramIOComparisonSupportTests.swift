// Tests/APITests/ProgramIOComparisonSupportTests.swift
//
// The `programIO` comparisons a language refuses, asked through ONE predicate
// (#1937). The save-time refusal, the `ioComparison` schema prose and the
// `get_server_info` payload all read `programIOComparisonUnsupportedReason`.
// Before it, the refusal was a `language != .lua` guard and the prose typed
// "Lua" by hand, and `get_server_info` reported neither this refusal nor the
// matching `cellContains` one.

import Core
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct ProgramIOComparisonSupportTests {

    private static func family(_ comparison: ProgramIOComparison) -> PatternFamily {
        PatternFamily(
            id: "io", name: "Echo", kind: .programIO, functionName: "", paramNames: ["stdin"],
            cases: [PatternCase(key: "01", label: "echo", args: [.string("7\n")], expected: .string("7"))],
            ioComparison: comparison)
    }

    /// The save refuses exactly the pairs the predicate refuses, with its reason.
    @Test(arguments: AssignmentLanguage.allCases, ProgramIOComparison.allCases)
    func theSaveRefusesExactlyWhatThePredicateRefuses(
        language: AssignmentLanguage, comparison: ProgramIOComparison
    ) throws {
        let reason = programIOComparisonUnsupportedReason(comparison, language: language)
        do {
            try validatePatternFamilies([Self.family(comparison)], testSuites: [], language: language)
            #expect(reason == nil, "the save accepted \(comparison) on \(language), which the predicate refuses")
        } catch let abort as any AbortError {
            let expected = try #require(
                reason, "the save refused \(comparison) on \(language), which the predicate allows: \(abort.reason)")
            #expect(abort.reason.contains(expected))
        }
    }

    /// The schema prose names the languages the predicate refuses, and no
    /// other. The clause is parsed out of the served text, not re-rendered.
    @Test func theFieldDescriptionNamesExactlyTheRefusingLanguages() throws {
        let text = MCPProgramIOProse.fieldDescription
        let refusing = Set(
            AssignmentLanguage.allCases
                .filter { programIOComparisonUnsupportedReason(.regex, language: $0) != nil }
                .map(\.displayName))
        let opening = try #require(text.range(of: "regex is refused on a "))
        let closing = try #require(text.range(of: " assignment.", range: opening.upperBound..<text.endIndex))
        let named = text[opening.upperBound..<closing.lowerBound]
            .replacingOccurrences(of: " or ", with: ", ")
            .components(separatedBy: ", ")
        #expect(Set(named) == refusing)
    }

    /// `get_server_info` reports every field-level refusal from the two
    /// predicates the saves call, and nothing else.
    @Test(arguments: AssignmentLanguage.allCases)
    func theCapabilityPayloadReportsEveryFieldRefusal(language: AssignmentLanguage) {
        var expected: [String: String] = [:]
        for kind in NotebookCheckKind.allCases
        where notebookCheckKindUnsupportedReason(kind, language: language) == nil {
            for field in formFields(for: kind) {
                if let reason = notebookCheckFieldUnsupportedReason(field.name, kind: kind, language: language) {
                    expected["\(kind.rawValue).\(field.name)"] = reason
                }
            }
        }
        for comparison in ProgramIOComparison.allCases {
            if let reason = programIOComparisonUnsupportedReason(comparison, language: language) {
                expected["program_io.ioComparison=\(comparison.rawValue)"] = reason
            }
        }
        #expect(MCPLanguageCapability(language).unsupportedFields == expected)
    }

    /// The concrete answer today: Lua refuses regex in both places, and the
    /// payload says so.
    @Test func luaReportsBothRegexRefusals() {
        let fields = MCPLanguageCapability(.lua).unsupportedFields
        #expect(fields["cell_contains.regex"] != nil)
        #expect(fields["program_io.ioComparison=regex"] != nil)
        #expect(MCPLanguageCapability(.python).unsupportedFields.isEmpty)
    }
}
