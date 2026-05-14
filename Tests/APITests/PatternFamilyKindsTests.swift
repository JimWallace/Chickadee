// Tests/APITests/PatternFamilyKindsTests.swift
//
// Split from PatternFamilyTests.swift.  See PatternFamilyTestCase.swift
// for shared family fixtures (bmiFamily, approxFamily,
// notebookVariablesFamily, helloPrintsFamily) and the Fixture plumbing
// helpers (makeFixture, writeEmptyZip, etc.).

import Core
import Crypto
import Fluent
import Foundation
import Vapor
import XCTest

@testable import chickadee_server

final class PatternFamilyKindsTests: PatternFamilyTestCase {

    // MARK: - approximateEquality kind

    func testRenderer_approxEquality_emitsToleranceComparison() {
        let rendered = renderPatternFamily(approxFamily(tolerance: 0.05))
        XCTAssertEqual(rendered.count, 2)
        let src = rendered[0].source
        XCTAssertTrue(
            src.contains("tolerance = 0.05"),
            "Expected Python literal for tolerance; got: \(src)")
        XCTAssertTrue(src.contains("delta = abs(result - expected)"))
        XCTAssertTrue(src.contains("if delta > tolerance:"))
        XCTAssertTrue(
            src.contains("wrong return type"),
            "Approx kind must also guard against non-numeric return types")
        XCTAssertTrue(src.contains("value outside tolerance"))
    }

    func testRenderer_approxEquality_defaultToleranceAppliedWhenNil() {
        let rendered = renderPatternFamily(approxFamily(tolerance: nil))
        let src = rendered[0].source
        // 1e-6 renders as Swift's "1e-06" via String(Double) — either form
        // is acceptable as a Python float literal.
        XCTAssertTrue(
            src.contains("tolerance = 1e-06") || src.contains("tolerance = 0.000001"),
            "Default tolerance (1e-6) missing from: \(src)")
    }

    func testRenderer_approxEquality_isValidPython() throws {
        let rendered = renderPatternFamily(approxFamily(tolerance: 0.01))
        for g in rendered {
            try assertValidPythonSyntax(g.source, label: g.filename)
        }
    }

    func testValidation_approxEquality_rejectsNegativeTolerance() {
        let family = PatternFamily(
            id: "bad", name: "bad", kind: .approximateEquality,
            functionName: "f", paramNames: ["x"],
            defaults: PatternDefaults(tolerance: -0.1),
            cases: [PatternCase(key: "01", label: "a", args: [.int(1)], expected: .int(1))]
        )
        XCTAssertThrowsError(try validatePatternFamilies([family], testSuites: [])) { err in
            XCTAssertTrue("\(err)".contains("tolerance"))
        }
    }

    func testValidation_approxEquality_acceptsZeroTolerance() {
        let family = PatternFamily(
            id: "strict", name: "strict", kind: .approximateEquality,
            functionName: "f", paramNames: ["x"],
            defaults: PatternDefaults(tolerance: 0),
            cases: [PatternCase(key: "01", label: "a", args: [.int(1)], expected: .int(1))]
        )
        XCTAssertNoThrow(try validatePatternFamilies([family], testSuites: []))
    }

    func testValidation_approxEquality_rejectsNonFiniteTolerance() {
        let family = PatternFamily(
            id: "nan", name: "nan", kind: .approximateEquality,
            functionName: "f", paramNames: ["x"],
            defaults: PatternDefaults(tolerance: .nan),
            cases: [PatternCase(key: "01", label: "a", args: [.int(1)], expected: .int(1))]
        )
        XCTAssertThrowsError(try validatePatternFamilies([family], testSuites: []))
    }

    // MARK: - variableEquality

    /// Fixture: a 2-case variable-equality family.  `functionName` is
    /// irrelevant (validation skips it) — we use a placeholder.
    func testVariableEqualityRendererChecksModuleAttr() {
        let rendered = renderPatternFamily(notebookVariablesFamily())
        XCTAssertEqual(rendered.count, 2)
        let src = rendered[0].source
        XCTAssertTrue(src.hasPrefix("# Test: beats equals 5\n"))
        XCTAssertTrue(src.contains("variable_name = \"beats\""))
        XCTAssertTrue(src.contains("expected      = 5"))
        XCTAssertTrue(src.contains("getattr(student_module, variable_name, _MISSING)"))
        XCTAssertTrue(src.contains("is not defined"))
        XCTAssertTrue(src.contains("has the wrong value"))
        // Must NOT call any student function.
        XCTAssertFalse(src.contains("student_module._"))
        XCTAssertFalse(src.contains("(beats)"))
    }

    func testVariableEqualityRendererFilenameFormat() {
        let rendered = renderPatternFamily(notebookVariablesFamily())
        XCTAssertEqual(rendered[0].filename, "publictest_notebook_variables_01.py")
        XCTAssertEqual(rendered[1].filename, "publictest_notebook_variables_02.py")
    }

    func testVariableEqualityRenderedSourceIsValidPython() throws {
        let rendered = renderPatternFamily(notebookVariablesFamily())
        for script in rendered {
            try assertValidPythonSyntax(script.source, label: script.filename)
        }
    }

    func testVariableEqualityValidation_acceptsGoodFamily() throws {
        try validatePatternFamilies([notebookVariablesFamily()], testSuites: [])
    }

    func testVariableEqualityValidation_rejectsCaseWithMultipleArgs() {
        let bad = PatternFamily(
            id: "bad", name: "Bad", kind: .variableEquality,
            functionName: "_", paramNames: ["variable"],
            cases: [
                PatternCase(
                    key: "01", label: "two args",
                    args: [.string("x"), .string("y")],
                    expected: .int(1))
            ]
        )
        XCTAssertThrowsError(try validatePatternFamilies([bad], testSuites: []))
    }

    func testVariableEqualityValidation_rejectsNonStringArg() {
        let bad = PatternFamily(
            id: "bad", name: "Bad", kind: .variableEquality,
            functionName: "_", paramNames: ["variable"],
            cases: [
                PatternCase(
                    key: "01", label: "number arg",
                    args: [.int(42)], expected: .int(1))
            ]
        )
        XCTAssertThrowsError(try validatePatternFamilies([bad], testSuites: []))
    }

    func testVariableEqualityValidation_rejectsEmptyVariableName() {
        let bad = PatternFamily(
            id: "bad", name: "Bad", kind: .variableEquality,
            functionName: "_", paramNames: ["variable"],
            cases: [
                PatternCase(
                    key: "01", label: "empty name",
                    args: [.string("")], expected: .int(1))
            ]
        )
        XCTAssertThrowsError(try validatePatternFamilies([bad], testSuites: []))
    }

    func testVariableEqualityValidation_rejectsNonIdentifierVariableName() {
        let bad = PatternFamily(
            id: "bad", name: "Bad", kind: .variableEquality,
            functionName: "_", paramNames: ["variable"],
            cases: [
                PatternCase(
                    key: "01", label: "bad name",
                    args: [.string("not a valid name")], expected: .int(1))
            ]
        )
        XCTAssertThrowsError(try validatePatternFamilies([bad], testSuites: []))
    }

    func testVariableEqualityValidation_allowsPlaceholderFunctionName() throws {
        // `.variableEquality` families don't call a function, so functionName
        // doesn't have to be a valid Python identifier.  Accept "_" or even
        // empty — the renderer and runtime both ignore it.
        let fam = PatternFamily(
            id: "ok", name: "OK", kind: .variableEquality,
            functionName: "",  // empty is fine
            paramNames: ["variable"],
            cases: [
                PatternCase(
                    key: "01", label: "a",
                    args: [.string("x")], expected: .int(1))
            ]
        )
        try validatePatternFamilies([fam], testSuites: [])
    }

    // MARK: - stdoutEquality

    func testStdoutEqualityRendererBasicShape() throws {
        let rendered = renderPatternFamily(helloPrintsFamily())
        XCTAssertEqual(rendered.count, 1)
        let src = rendered[0].source
        XCTAssertTrue(src.hasPrefix("# Test: prints greeting\n"))
        XCTAssertTrue(src.contains("import contextlib as _contextlib"))
        XCTAssertTrue(src.contains("with _contextlib.redirect_stdout(_buf):"))
        XCTAssertTrue(src.contains("student_module.say_hi(name)"))
        XCTAssertTrue(src.contains("expected = \"hi world\""))
        XCTAssertTrue(src.contains("wrong stdout"))
        XCTAssertTrue(src.contains("Printed"))
        try assertValidPythonSyntax(src, label: rendered[0].filename)
    }

    func testStdoutEqualityRendererFilenameFormat() {
        let rendered = renderPatternFamily(helloPrintsFamily())
        XCTAssertEqual(rendered[0].filename, "publictest_hello_prints_01.py")
    }

    func testStdoutEqualityRendererPreservesMultilineExpected() throws {
        // A multi-line Expected (the natural shape for two `print()`
        // calls) must round-trip through the Python literal without
        // breaking the source.  The single-trailing-newline trim is
        // applied at runtime, not at rendering — the literal in the
        // source still carries the trailing \n that the instructor
        // typed.
        let fam = helloPrintsFamily(expected: "a\nb\n")
        let rendered = renderPatternFamily(fam)
        let src = rendered[0].source
        XCTAssertTrue(src.contains(#"expected = "a\nb\n""#))
        try assertValidPythonSyntax(src, label: rendered[0].filename)
    }

    func testStdoutEqualityValidationAllowsEmptyExpected() throws {
        // "this function should print nothing" is a legitimate case.
        let fam = PatternFamily(
            id: "silent", name: "Silent", kind: .stdoutEquality,
            functionName: "say", paramNames: ["x"],
            cases: [
                PatternCase(
                    key: "01", label: "prints nothing",
                    args: [.int(1)], expected: .string(""))
            ]
        )
        try validatePatternFamilies([fam], testSuites: [])
    }

    func testStdoutEqualityValidationRejectsNonStringExpected() {
        let bad = PatternFamily(
            id: "bad", name: "Bad", kind: .stdoutEquality,
            functionName: "say", paramNames: ["x"],
            cases: [
                PatternCase(
                    key: "01", label: "non-string",
                    args: [.int(1)], expected: .int(42))
            ]
        )
        XCTAssertThrowsError(try validatePatternFamilies([bad], testSuites: []))
    }

    func testStdoutEqualityValidationRejectsArgArityMismatch() {
        let bad = PatternFamily(
            id: "bad", name: "Bad", kind: .stdoutEquality,
            functionName: "say", paramNames: ["x", "y"],
            cases: [
                PatternCase(
                    key: "01", label: "wrong arity",
                    args: [.int(1)], expected: .string("hi"))
            ]
        )
        XCTAssertThrowsError(try validatePatternFamilies([bad], testSuites: []))
    }

    func testStdoutEqualitySpecHashChangesWithExpected() {
        let a = patternFamilySpecHash(helloPrintsFamily(expected: "hi"))
        let b = patternFamilySpecHash(helloPrintsFamily(expected: "bye"))
        XCTAssertNotEqual(a, b)
    }
}
