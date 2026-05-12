// Tests/APITests/NotebookCheckVariableExistsTests.swift
//
// Unit coverage for `NotebookCheckKind.variableExists` — the lightweight
// existence-only sibling to `.functionExists`.  Tests the renderer's
// Python output shape (existence-only and existence + type variants),
// the default label, and the validator's required/optional field rules.

import XCTest
@testable import chickadee_server
import Core
import Foundation
import Vapor

final class NotebookCheckVariableExistsTests: XCTestCase {

    // MARK: - Renderer

    func testRender_existenceOnly_emitsMissingSentinelAndNoTypeCheck() {
        let check = NotebookCheck(
            id: "var_df",
            kind: .variableExists,
            variable: "df"
        )
        let bundle = renderNotebookCheck(check)
        let source = bundle.script.source

        XCTAssertTrue(source.contains("kind=variable_exists"),
            "header should record the kind for stale-script audits")
        XCTAssertTrue(source.contains("name = \"df\""),
            "variable name should be embedded as a Python string literal")
        XCTAssertTrue(source.contains("getattr(student_module, name, _MISSING)"),
            "must use the standard _MISSING sentinel idiom")
        XCTAssertTrue(source.contains("is not defined in the student notebook"),
            "missing-variable failure message should be present")
        XCTAssertTrue(source.contains("# (no type check; existence only)"),
            "no-type branch should include the explicit no-op comment")
        XCTAssertFalse(source.contains("isinstance"),
            "no isinstance check should appear when expectedType is nil")
        XCTAssertFalse(source.contains("__mro__"),
            "no MRO walk should appear when expectedType is nil")
        XCTAssertTrue(source.contains("passed("),
            "must emit a pass message on success")
        XCTAssertEqual(bundle.sidecars.count, 0,
            "variableExists never produces sidecars")
    }

    func testRender_withBuiltinType_emitsIsinstanceCheck() {
        let check = NotebookCheck(
            id: "var_n",
            kind: .variableExists,
            variable: "n",
            expectedType: "int"
        )
        let source = renderNotebookCheck(check).script.source

        XCTAssertTrue(source.contains("expected_type_name = \"int\""))
        XCTAssertTrue(source.contains("isinstance(actual, int) and not isinstance(actual, bool)"),
            "int check must exclude bool (matches PatternFamilyRenderer's returnTypeCheck)")
        XCTAssertTrue(source.contains("has the wrong type"),
            "type mismatch failure message should be present")
    }

    func testRender_withLibraryType_walksMROByName() {
        let check = NotebookCheck(
            id: "var_df",
            kind: .variableExists,
            variable: "df",
            expectedType: "DataFrame"
        )
        let source = renderNotebookCheck(check).script.source

        XCTAssertTrue(source.contains("__mro__"),
            "library types should be matched via MRO-name walk to avoid forcing imports")
        XCTAssertTrue(source.contains(#""DataFrame""#))
    }

    func testRender_withUnknownType_fallsBackToMROWalk() {
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

        XCTAssertTrue(source.contains("__mro__"))
        XCTAssertTrue(source.contains(#""MyCustomClass""#))
    }

    func testFilename_usesCheckPrefix_andNoSidecars() {
        let check = NotebookCheck(
            id: "var_df", kind: .variableExists,
            tier: .release, variable: "df"
        )
        let files = notebookCheckAllGeneratedFilenames(check)
        XCTAssertEqual(files, ["releasecheck_var_df.py"],
            "variableExists generates a single .py with the tier-prefixed name")
    }

    // MARK: - Default label

    func testDefaultLabel_withoutType() {
        let check = NotebookCheck(
            id: "var_results",
            kind: .variableExists,
            variable: "results"
        )
        let source = renderNotebookCheck(check).script.source
        XCTAssertTrue(source.contains("# Test: `results` is defined"),
            "default label should describe pure existence")
    }

    func testDefaultLabel_withType() {
        let check = NotebookCheck(
            id: "var_df",
            kind: .variableExists,
            variable: "df",
            expectedType: "DataFrame"
        )
        let source = renderNotebookCheck(check).script.source
        XCTAssertTrue(source.contains("# Test: `df` is defined and is a DataFrame"),
            "default label should describe existence + type")
    }

    // MARK: - Validator

    func testValidate_passesForBareExistence() throws {
        let checks = [
            NotebookCheck(id: "ok", kind: .variableExists, variable: "df"),
        ]
        XCTAssertNoThrow(try validateNotebookChecks(checks))
    }

    func testValidate_passesForExistencePlusType() throws {
        let checks = [
            NotebookCheck(id: "ok", kind: .variableExists,
                          variable: "df", expectedType: "DataFrame"),
        ]
        XCTAssertNoThrow(try validateNotebookChecks(checks))
    }

    func testValidate_rejectsMissingVariable() {
        let checks = [
            NotebookCheck(id: "bad", kind: .variableExists, variable: nil),
        ]
        XCTAssertThrowsError(try validateNotebookChecks(checks)) { err in
            XCTAssertTrue("\(err)".contains("variable name is required"))
        }
    }

    func testValidate_rejectsEmptyVariable() {
        let checks = [
            NotebookCheck(id: "bad", kind: .variableExists, variable: ""),
        ]
        XCTAssertThrowsError(try validateNotebookChecks(checks))
    }

    func testValidate_rejectsNonIdentifierVariable() {
        let checks = [
            NotebookCheck(id: "bad", kind: .variableExists, variable: "1df"),
        ]
        XCTAssertThrowsError(try validateNotebookChecks(checks)) { err in
            XCTAssertTrue("\(err)".contains("not a valid Python identifier"))
        }
    }

    func testValidate_rejectsWhitespaceOnlyExpectedType() {
        let checks = [
            NotebookCheck(id: "bad", kind: .variableExists,
                          variable: "df", expectedType: "   "),
        ]
        XCTAssertThrowsError(try validateNotebookChecks(checks)) { err in
            XCTAssertTrue("\(err)".contains("expectedType"))
        }
    }
}
