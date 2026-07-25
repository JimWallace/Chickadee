// Tests/APITests/NotebookCheckValidationHardeningTests.swift
//
// Two notebook-check validation hardening fixes:
//
//   1. `cell_contains` regex sanity understood raw `(`/`)` counts and a
//      `hasSuffix("\\")` test, so an escaped `\(`, a paren inside a `[...]`
//      character class, or a literal trailing `\\` were wrongly rejected as
//      "unbalanced parentheses" / "dangling backslash". The scan now tracks
//      escape state and character-class nesting. (Affects Python authors too.)
//
//   2. Name fields (`variable`, function names) were validated as *Python*
//      identifiers on every assignment, so an idiomatic R name like `my.df`
//      was refused on an R assignment. Validation now dispatches on the
//      assignment language via `isValidRIdentifier`.

import Core
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct NotebookCheckValidationHardeningTests {

    // MARK: - item 1: cell_contains regex sanity

    private func cellContains(_ needle: String, regex: Bool) -> [NotebookCheck] {
        [NotebookCheck(id: "c", kind: .cellContains, containsText: needle, regex: regex)]
    }

    @Test func regex_acceptsEscapedParen() throws {
        // `\(` is an escaped literal, not an opening group — the naive counter
        // saw one `(` and zero `)` and rejected it. This is the real-world
        // needle from the R Assignment 4 conversion.
        try validateNotebookChecks(cellContains(#"summary\s*\("#, regex: true))
    }

    @Test func regex_acceptsParenInsideCharacterClass() throws {
        try validateNotebookChecks(cellContains("[()]+", regex: true))
    }

    @Test func regex_acceptsBalancedGroups() throws {
        try validateNotebookChecks(cellContains("(a|b)(c)", regex: true))
    }

    @Test func regex_acceptsLiteralTrailingBackslashPair() throws {
        // `\\` is an escaped backslash, not a dangling escape.
        try validateNotebookChecks(cellContains(#"path\\"#, regex: true))
    }

    @Test func regex_rejectsUnbalancedOpen() {
        #expect(throws: (any Error).self) {
            try validateNotebookChecks(cellContains("(a", regex: true))
        }
    }

    @Test func regex_rejectsUnbalancedClose() {
        #expect(throws: (any Error).self) {
            try validateNotebookChecks(cellContains("a)", regex: true))
        }
    }

    @Test func regex_rejectsDanglingBackslash() {
        #expect(throws: (any Error).self) {
            try validateNotebookChecks(cellContains(#"abc\"#, regex: true))
        }
    }

    @Test func nonRegex_skipsParenSanity() throws {
        // A plain substring needle is not a regex, so unbalanced parens in it
        // (matching literal source like `f(x`) must not be rejected.
        try validateNotebookChecks(cellContains("f(x", regex: false))
    }

    // MARK: - item 2: R identifier names

    @Test func isValidRIdentifier_acceptsIdiomaticNames() {
        for name in ["x", "my.df", "df2", ".hidden", "a_b.c", "T"] {
            #expect(isValidRIdentifier(name), "\(name) should be a valid R name")
        }
    }

    @Test func isValidRIdentifier_rejectsInvalidNames() {
        // Empty, Python-style leading underscore, leading digit, dot-then-digit,
        // a hyphen, and R reserved words.
        for name in ["", "_x", "1df", ".2way", "a-b", "function", "if", "NULL"] {
            #expect(!isValidRIdentifier(name), "\(name) should not be a valid R name")
        }
    }

    @Test func variableName_dotName_passesOnRAssignment() throws {
        let checks = [NotebookCheck(id: "c", kind: .variableExists, variable: "my.df")]
        try validateNotebookChecks(checks, language: .r)
    }

    @Test func variableName_dotName_rejectedOnPythonAssignment() throws {
        let checks = [NotebookCheck(id: "c", kind: .variableExists, variable: "my.df")]
        let error = try #require(
            throws: (any Error).self
        ) {
            try validateNotebookChecks(checks, language: .python)
        }
        #expect("\(error)".contains("not a valid Python identifier"))
    }

    @Test func variableName_leadingUnderscore_rejectedOnRAssignment() throws {
        let checks = [NotebookCheck(id: "c", kind: .variableExists, variable: "_x")]
        let error = try #require(
            throws: (any Error).self
        ) {
            try validateNotebookChecks(checks, language: .r)
        }
        #expect("\(error)".contains("not a valid R name"))
    }

    @Test func functionName_dotName_passesOnRAssignment() throws {
        let checks = [NotebookCheck(id: "c", kind: .functionExists, variable: "my.func")]
        try validateNotebookChecks(checks, language: .r)
    }
}
