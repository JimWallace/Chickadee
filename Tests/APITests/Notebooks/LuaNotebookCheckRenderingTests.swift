// Tests/APITests/Notebooks/LuaNotebookCheckRenderingTests.swift
//
// The Lua notebook-check renderer paths that the conformance matrix does not
// reach: a kind Lua cannot render (which must error, never pass), the
// optional type guard on `variable_exists`, and the must-differ-from block on
// `cell_contains`.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct LuaNotebookCheckRenderingTests {

    // MARK: - Unsupported kinds

    static let unsupportedKinds: [NotebookCheckKind] = NotebookCheckKind.allCases.filter {
        !notebookCheckKindSupportsLua($0)
    }

    @Test func theSupportedKindsAreTheFourWithALuaBody() {
        let supported = Set(NotebookCheckKind.allCases.filter(notebookCheckKindSupportsLua))
        #expect(supported == [.variableExists, .functionExists, .numericArrayClose, .cellContains])
    }

    /// A check that slips past validation must not award marks nobody
    /// verified: the script errors and names the kind.
    @Test(arguments: unsupportedKinds)
    func anUnsupportedKindRendersAScriptThatErrorsAndNamesTheKind(_ kind: NotebookCheckKind) {
        let check = NotebookCheck(id: "chk", kind: kind, variable: "df")
        let script = renderLuaNotebookCheck(check, specHash: "abc")
        #expect(script.hasPrefix("-- Test: unsupported check\n"))
        #expect(script.contains("[chk] spec_hash=abc"))
        #expect(
            script.contains(
                "chickadee.errored(\"The '\(kind.rawValue)' notebook check is not available for Lua assignments.\")"))
        #expect(!script.contains("chickadee.passed("))
    }

    // MARK: - variable_exists type guard

    @Test func anExpectedTypeAddsATypeGuardBeforeThePass() throws {
        let check = NotebookCheck(id: "v", kind: .variableExists, variable: "counts", expectedType: "table")
        let script = renderLuaNotebookCheck(check, specHash: "h")
        let guardRange = try #require(script.range(of: "if not (type(actual) == \"table\") then"))
        let passRange = try #require(script.range(of: "chickadee.passed("))
        #expect(guardRange.lowerBound < passRange.lowerBound)
        #expect(script.contains("\"table\", \"\\n\","))
    }

    @Test func anIntegerTypeUsesMathType() {
        let check = NotebookCheck(id: "v", kind: .variableExists, variable: "n", expectedType: "int")
        let script = renderLuaNotebookCheck(check, specHash: "h")
        #expect(script.contains("if not (math.type(actual) == \"integer\") then"))
    }

    @Test(arguments: [nil, ""] as [String?])
    func noExpectedTypeMeansNoTypeGuard(_ expectedType: String?) {
        let check = NotebookCheck(id: "v", kind: .variableExists, variable: "n", expectedType: expectedType)
        let script = renderLuaNotebookCheck(check, specHash: "h")
        #expect(!script.contains("if not ("))
        #expect(script.contains("chickadee.passed("))
    }

    // MARK: - cell_contains must-differ-from

    @Test func aMustDifferFromTextFailsACopyOfTheExample() throws {
        let check = NotebookCheck(
            id: "c", kind: .cellContains, containsText: "plot(", mustDifferFrom: "plot(x)\n")
        let script = renderLuaNotebookCheck(check, specHash: "h")
        #expect(script.contains("local must_differ_from = \"plot(x)\\n\""))
        #expect(script.contains("local function ck_normalize(s)"))
        // One differing cell is enough to clear the copy check.
        #expect(script.contains("if ck_normalize(cell) ~= reference then"))
        #expect(script.contains("is identical to the example"))
        #expect(!script.contains("(no must-differ-from constraint)"))
        // The copy check runs after a match is found, and before the pass.
        let noMatch = try #require(script.range(of: "if #matched == 0 then"))
        let copyCheck = try #require(script.range(of: "if all_identical then"))
        let pass = try #require(script.range(of: "chickadee.passed("))
        #expect(noMatch.lowerBound < copyCheck.lowerBound)
        #expect(copyCheck.lowerBound < pass.lowerBound)
    }

    @Test func withoutMustDifferFromThereIsNoCopyCheck() {
        let check = NotebookCheck(id: "c", kind: .cellContains, containsText: "plot(")
        let script = renderLuaNotebookCheck(check, specHash: "h")
        #expect(script.contains("-- (no must-differ-from constraint)"))
        #expect(!script.contains("all_identical"))
    }
}
