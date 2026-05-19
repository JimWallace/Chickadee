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
import Testing
import Vapor

@testable import APIServer

@Suite struct PatternFamilyKindsTests {

    // MARK: - approximateEquality kind

    @Test func renderer_approxEquality_emitsToleranceComparison() throws {
        let rendered = renderPatternFamily(pfApproxFamily(tolerance: 0.05))
        #expect(rendered.count == 2)
        let src = rendered[0].source
        #expect(
            src.contains("tolerance = 0.05"),
            "Expected Python literal for tolerance; got: \(src)")
        #expect(src.contains("delta = abs(result - expected)"))
        #expect(src.contains("if delta > tolerance:"))
        #expect(
            src.contains("wrong return type"),
            "Approx kind must also guard against non-numeric return types")
        #expect(src.contains("value outside tolerance"))
    }

    @Test func renderer_approxEquality_defaultToleranceAppliedWhenNil() throws {
        let rendered = renderPatternFamily(pfApproxFamily(tolerance: nil))
        let src = rendered[0].source
        // 1e-6 renders as Swift's "1e-06" via String(Double) — either form
        // is acceptable as a Python float literal.
        #expect(
            src.contains("tolerance = 1e-06") || src.contains("tolerance = 0.000001"),
            "Default tolerance (1e-6) missing from: \(src)")
    }

    @Test func renderer_approxEquality_isValidPython() throws {
        let rendered = renderPatternFamily(pfApproxFamily(tolerance: 0.01))
        for g in rendered {
            try pfAssertValidPythonSyntax(g.source, label: g.filename)
        }
    }

    @Test func validation_approxEquality_rejectsNegativeTolerance() throws {
        let family = PatternFamily(
            id: "bad", name: "bad", kind: .approximateEquality,
            functionName: "f", paramNames: ["x"],
            defaults: PatternDefaults(tolerance: -0.1),
            cases: [PatternCase(key: "01", label: "a", args: [.int(1)], expected: .int(1))]
        )
        #expect { try validatePatternFamilies([family], testSuites: []) } throws: { error in
            #expect("\(error)".contains("tolerance"))

            return true
        }
    }

    @Test func validation_approxEquality_acceptsZeroTolerance() throws {
        let family = PatternFamily(
            id: "strict", name: "strict", kind: .approximateEquality,
            functionName: "f", paramNames: ["x"],
            defaults: PatternDefaults(tolerance: 0),
            cases: [PatternCase(key: "01", label: "a", args: [.int(1)], expected: .int(1))]
        )
        try validatePatternFamilies([family], testSuites: [])
    }

    @Test func validation_approxEquality_rejectsNonFiniteTolerance() throws {
        let family = PatternFamily(
            id: "nan", name: "nan", kind: .approximateEquality,
            functionName: "f", paramNames: ["x"],
            defaults: PatternDefaults(tolerance: .nan),
            cases: [PatternCase(key: "01", label: "a", args: [.int(1)], expected: .int(1))]
        )
        #expect(throws: (any Error).self) { try validatePatternFamilies([family], testSuites: []) }
    }

    // MARK: - variableEquality

    /// Fixture: a 2-case variable-equality family.  `functionName` is
    /// irrelevant (validation skips it) — we use a placeholder.
    @Test func variableEqualityRendererChecksModuleAttr() throws {
        let rendered = renderPatternFamily(pfNotebookVariablesFamily())
        #expect(rendered.count == 2)
        let src = rendered[0].source
        #expect(src.hasPrefix("# Test: beats equals 5\n"))
        #expect(src.contains("variable_name = \"beats\""))
        #expect(src.contains("expected      = 5"))
        #expect(src.contains("getattr(student_module, variable_name, _MISSING)"))
        #expect(src.contains("is not defined"))
        #expect(src.contains("has the wrong value"))
        // Must NOT call any student function.
        #expect(src.contains("student_module._") == false)
        #expect(src.contains("(beats)") == false)
    }

    @Test func variableEqualityRendererFilenameFormat() throws {
        let rendered = renderPatternFamily(pfNotebookVariablesFamily())
        #expect(rendered[0].filename == "publictest_notebook_variables_01.py")
        #expect(rendered[1].filename == "publictest_notebook_variables_02.py")
    }

    @Test func variableEqualityRenderedSourceIsValidPython() throws {
        let rendered = renderPatternFamily(pfNotebookVariablesFamily())
        for script in rendered {
            try pfAssertValidPythonSyntax(script.source, label: script.filename)
        }
    }

    @Test func variableEqualityValidation_acceptsGoodFamily() throws {
        try validatePatternFamilies([pfNotebookVariablesFamily()], testSuites: [])
    }

    @Test func variableEqualityValidation_rejectsCaseWithMultipleArgs() throws {
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
        #expect(throws: (any Error).self) { try validatePatternFamilies([bad], testSuites: []) }
    }

    @Test func variableEqualityValidation_rejectsNonStringArg() throws {
        let bad = PatternFamily(
            id: "bad", name: "Bad", kind: .variableEquality,
            functionName: "_", paramNames: ["variable"],
            cases: [
                PatternCase(
                    key: "01", label: "number arg",
                    args: [.int(42)], expected: .int(1))
            ]
        )
        #expect(throws: (any Error).self) { try validatePatternFamilies([bad], testSuites: []) }
    }

    @Test func variableEqualityValidation_rejectsEmptyVariableName() throws {
        let bad = PatternFamily(
            id: "bad", name: "Bad", kind: .variableEquality,
            functionName: "_", paramNames: ["variable"],
            cases: [
                PatternCase(
                    key: "01", label: "empty name",
                    args: [.string("")], expected: .int(1))
            ]
        )
        #expect(throws: (any Error).self) { try validatePatternFamilies([bad], testSuites: []) }
    }

    @Test func variableEqualityValidation_rejectsNonIdentifierVariableName() throws {
        let bad = PatternFamily(
            id: "bad", name: "Bad", kind: .variableEquality,
            functionName: "_", paramNames: ["variable"],
            cases: [
                PatternCase(
                    key: "01", label: "bad name",
                    args: [.string("not a valid name")], expected: .int(1))
            ]
        )
        #expect(throws: (any Error).self) { try validatePatternFamilies([bad], testSuites: []) }
    }

    @Test func variableEqualityValidation_allowsPlaceholderFunctionName() throws {
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

    @Test func stdoutEqualityRendererBasicShape() throws {
        let rendered = renderPatternFamily(pfHelloPrintsFamily())
        #expect(rendered.count == 1)
        let src = rendered[0].source
        #expect(src.hasPrefix("# Test: prints greeting\n"))
        #expect(src.contains("import contextlib as _contextlib"))
        #expect(src.contains("with _contextlib.redirect_stdout(_buf):"))
        #expect(src.contains("student_module.say_hi(name)"))
        #expect(src.contains("expected = \"hi world\""))
        #expect(src.contains("wrong stdout"))
        #expect(src.contains("Printed"))
        try pfAssertValidPythonSyntax(src, label: rendered[0].filename)
    }

    @Test func stdoutEqualityRendererFilenameFormat() throws {
        let rendered = renderPatternFamily(pfHelloPrintsFamily())
        #expect(rendered[0].filename == "publictest_hello_prints_01.py")
    }

    @Test func stdoutEqualityRendererPreservesMultilineExpected() throws {
        // A multi-line Expected (the natural shape for two `print()`
        // calls) must round-trip through the Python literal without
        // breaking the source.  The single-trailing-newline trim is
        // applied at runtime, not at rendering — the literal in the
        // source still carries the trailing \n that the instructor
        // typed.
        let fam = pfHelloPrintsFamily(expected: "a\nb\n")
        let rendered = renderPatternFamily(fam)
        let src = rendered[0].source
        #expect(src.contains(#"expected = "a\nb\n""#))
        try pfAssertValidPythonSyntax(src, label: rendered[0].filename)
    }

    @Test func stdoutEqualityValidationAllowsEmptyExpected() throws {
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

    @Test func stdoutEqualityValidationRejectsNonStringExpected() throws {
        let bad = PatternFamily(
            id: "bad", name: "Bad", kind: .stdoutEquality,
            functionName: "say", paramNames: ["x"],
            cases: [
                PatternCase(
                    key: "01", label: "non-string",
                    args: [.int(1)], expected: .int(42))
            ]
        )
        #expect(throws: (any Error).self) { try validatePatternFamilies([bad], testSuites: []) }
    }

    @Test func stdoutEqualityValidationRejectsArgArityMismatch() throws {
        let bad = PatternFamily(
            id: "bad", name: "Bad", kind: .stdoutEquality,
            functionName: "say", paramNames: ["x", "y"],
            cases: [
                PatternCase(
                    key: "01", label: "wrong arity",
                    args: [.int(1)], expected: .string("hi"))
            ]
        )
        #expect(throws: (any Error).self) { try validatePatternFamilies([bad], testSuites: []) }
    }

    @Test func stdoutEqualitySpecHashChangesWithExpected() throws {
        let a = patternFamilySpecHash(pfHelloPrintsFamily(expected: "hi"))
        let b = patternFamilySpecHash(pfHelloPrintsFamily(expected: "bye"))
        #expect(a != b)
    }
}
