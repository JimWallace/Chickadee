// Tests/APITests/NotebookCheckVariableExistsTests.swift
//
// Unit coverage for `NotebookCheckKind.variableExists` — the lightweight
// existence-only sibling to `.functionExists`.  Tests the renderer's
// Python output shape (existence-only and existence + type variants),
// the default label, and the validator's required/optional field rules.

import Core
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct NotebookCheckVariableExistsTests {

    // MARK: - Renderer

    @Test func render_existenceOnly_emitsMissingSentinelAndNoTypeCheck() {
        let check = NotebookCheck(
            id: "var_df",
            kind: .variableExists,
            variable: "df"
        )
        let bundle = renderNotebookCheck(check)
        let source = bundle.script.source

        #expect(
            source.contains("kind=variable_exists"),
            "header should record the kind for stale-script audits")
        #expect(
            source.contains("name = \"df\""),
            "variable name should be embedded as a Python string literal")
        #expect(
            source.contains("getattr(student_module, name, _MISSING)"),
            "must use the standard _MISSING sentinel idiom")
        #expect(
            source.contains("is not defined in the student notebook"),
            "missing-variable failure message should be present")
        #expect(
            source.contains("# (no type check; existence only)"),
            "no-type branch should include the explicit no-op comment")
        #expect(source.contains("isinstance") == false, "no isinstance check should appear when expectedType is nil")
        #expect(source.contains("__mro__") == false, "no MRO walk should appear when expectedType is nil")
        #expect(
            source.contains("passed("),
            "must emit a pass message on success")
        #expect(bundle.sidecars.isEmpty, "variableExists never produces sidecars")
    }

    @Test func render_withBuiltinType_emitsIsinstanceCheck() {
        let check = NotebookCheck(
            id: "var_n",
            kind: .variableExists,
            variable: "n",
            expectedType: "int"
        )
        let source = renderNotebookCheck(check).script.source

        #expect(source.contains("expected_type_name = \"int\""))
        #expect(
            source.contains("isinstance(actual, int) and not isinstance(actual, bool)"),
            "int check must exclude bool (matches PatternFamilyRenderer's returnTypeCheck)")
        #expect(
            source.contains("has the wrong type"),
            "type mismatch failure message should be present")
    }

    @Test func render_withLibraryType_walksMROByName() {
        let check = NotebookCheck(
            id: "var_df",
            kind: .variableExists,
            variable: "df",
            expectedType: "DataFrame"
        )
        let source = renderNotebookCheck(check).script.source

        #expect(
            source.contains("__mro__"),
            "library types should be matched via MRO-name walk to avoid forcing imports")
        #expect(source.contains(#""DataFrame""#))
    }

    @Test func render_withUnknownType_fallsBackToMROWalk() {
        // Validator allows any non-empty type name; the renderer's MRO
        // fallback handles unknown names (student-defined classes, new
        // library types).  This mirrors `.returnTypeCheck`'s behaviour.
        let check = NotebookCheck(
            id: "var_custom",
            kind: .variableExists,
            variable: "obj",
            expectedType: "MyCustomClass"
        )
        let source = renderNotebookCheck(check).script.source

        #expect(source.contains("__mro__"))
        #expect(source.contains(#""MyCustomClass""#))
    }

    @Test func filename_usesCheckPrefix_andNoSidecars() {
        let check = NotebookCheck(
            id: "var_df", kind: .variableExists,
            tier: .release, variable: "df"
        )
        let files = notebookCheckAllGeneratedFilenames(check)
        #expect(
            files == ["releasecheck_var_df.py"], "variableExists generates a single .py with the tier-prefixed name")
    }

    // MARK: - Default label

    @Test func defaultLabel_withoutType() {
        let check = NotebookCheck(
            id: "var_results",
            kind: .variableExists,
            variable: "results"
        )
        let source = renderNotebookCheck(check).script.source
        #expect(
            source.contains("# Test: `results` is defined"),
            "default label should describe pure existence")
    }

    @Test func defaultLabel_withType() {
        let check = NotebookCheck(
            id: "var_df",
            kind: .variableExists,
            variable: "df",
            expectedType: "DataFrame"
        )
        let source = renderNotebookCheck(check).script.source
        #expect(
            source.contains("# Test: `df` is defined and is a DataFrame"),
            "default label should describe existence + type")
    }

    // MARK: - Validator

    @Test func validate_passesForBareExistence() throws {
        let checks = [
            NotebookCheck(id: "ok", kind: .variableExists, variable: "df")
        ]
        try validateNotebookChecks(checks)
    }

    @Test func validate_passesForExistencePlusType() throws {
        let checks = [
            NotebookCheck(
                id: "ok", kind: .variableExists,
                variable: "df", expectedType: "DataFrame")
        ]
        try validateNotebookChecks(checks)
    }

    @Test func validate_rejectsMissingVariable() throws {
        let checks = [
            NotebookCheck(id: "bad", kind: .variableExists, variable: nil)
        ]
        let error = try #require(throws: (any Error).self) {
            try validateNotebookChecks(checks)
        }
        #expect("\(error)".contains("variable name is required"))
    }

    @Test func validate_rejectsEmptyVariable() {
        let checks = [
            NotebookCheck(id: "bad", kind: .variableExists, variable: "")
        ]
        #expect(throws: (any Error).self) {
            try validateNotebookChecks(checks)
        }
    }

    @Test func validate_rejectsNonIdentifierVariable() throws {
        let checks = [
            NotebookCheck(id: "bad", kind: .variableExists, variable: "1df")
        ]
        let error = try #require(throws: (any Error).self) {
            try validateNotebookChecks(checks)
        }
        #expect("\(error)".contains("not a valid Python identifier"))
    }

    @Test func validate_rejectsWhitespaceOnlyExpectedType() throws {
        let checks = [
            NotebookCheck(
                id: "bad", kind: .variableExists,
                variable: "df", expectedType: "   ")
        ]
        let error = try #require(throws: (any Error).self) {
            try validateNotebookChecks(checks)
        }
        #expect("\(error)".contains("expectedType"))
    }
}
