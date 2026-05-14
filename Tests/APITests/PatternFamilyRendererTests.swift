// Tests/APITests/PatternFamilyRendererTests.swift
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

final class PatternFamilyRendererTests: PatternFamilyTestCase {

    // MARK: - JSONValue

    func testJSONValueRoundTripForEachVariant() throws {
        let samples: [JSONValue] = [
            .null,
            .bool(true), .bool(false),
            .int(0), .int(-42),
            .double(18.49), .double(-0.5),
            .string("hello"), .string("needs \"escaping\" & newline\n"),
            .array([.int(1), .string("x"), .null]),
            .object(["k": .int(1), "a": .array([.bool(true)])]),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        for sample in samples {
            let data = try encoder.encode(sample)
            let back = try decoder.decode(JSONValue.self, from: data)
            XCTAssertEqual(sample, back, "round-trip mismatch for \(sample)")
        }
    }

    func testJSONValuePythonLiteralForScalars() {
        XCTAssertEqual(JSONValue.null.pythonLiteral, "None")
        XCTAssertEqual(JSONValue.bool(true).pythonLiteral, "True")
        XCTAssertEqual(JSONValue.bool(false).pythonLiteral, "False")
        XCTAssertEqual(JSONValue.int(42).pythonLiteral, "42")
        XCTAssertEqual(JSONValue.double(18.49).pythonLiteral, "18.49")
        XCTAssertEqual(JSONValue.string("hi").pythonLiteral, "\"hi\"")
        XCTAssertEqual(JSONValue.string("a\"b").pythonLiteral, "\"a\\\"b\"")
        XCTAssertEqual(JSONValue.string("line\nbreak").pythonLiteral, "\"line\\nbreak\"")
    }

    func testJSONValuePythonLiteralForArraysAndObjects() {
        XCTAssertEqual(
            JSONValue.array([.int(1), .int(2), .int(3)]).pythonLiteral,
            "[1, 2, 3]"
        )
        XCTAssertEqual(
            JSONValue.object(["b": .int(2), "a": .int(1)]).pythonLiteral,
            #"{"a": 1, "b": 2}"#,
            "Object keys must be emitted in sorted order for determinism"
        )
    }

    // MARK: - Renderer

    func testRendererIsDeterministic() {
        let family = bmiFamily()
        let first = renderPatternFamily(family)
        let second = renderPatternFamily(family)
        XCTAssertEqual(first, second, "Same input must produce byte-identical output")
    }

    func testRendererSkipsDisabledCases() {
        var cases = bmiFamily().cases
        cases[1] = PatternCase(
            key: cases[1].key, label: cases[1].label,
            args: cases[1].args, expected: cases[1].expected,
            enabled: false
        )
        let family = PatternFamily(
            id: "bmi", name: "BMI", kind: .boundaryEquality,
            functionName: "bmi_category", paramNames: ["bmi"],
            cases: cases
        )
        let rendered = renderPatternFamily(family)
        XCTAssertEqual(rendered.count, 2)
        XCTAssertFalse(rendered.map(\.caseKey).contains(cases[1].key))
    }

    func testRendererFilenameFormat() {
        let rendered = renderPatternFamily(bmiFamily())
        XCTAssertEqual(rendered[0].filename, "publictest_bmi_category_01.py")
        XCTAssertEqual(rendered[1].filename, "publictest_bmi_category_02.py")
        XCTAssertEqual(rendered[2].filename, "publictest_bmi_category_03.py")
    }

    func testRendererPerCaseTierOverrideDrivesFilenamePrefix() {
        let family = PatternFamily(
            id: "mix", name: "Mixed tiers", kind: .boundaryEquality,
            functionName: "f", paramNames: ["x"],
            defaults: PatternDefaults(tier: .pub),
            cases: [
                PatternCase(key: "a", label: "pub", args: [.int(1)], expected: .int(1)),
                PatternCase(key: "b", label: "secret", args: [.int(2)], expected: .int(2), tier: .secret),
            ]
        )
        let rendered = renderPatternFamily(family)
        XCTAssertEqual(rendered[0].filename, "publictest_mix_a.py")
        XCTAssertEqual(rendered[1].filename, "secrettest_mix_b.py")
    }

    func testRendererSourceContainsRichFeedbackElements() {
        let rendered = renderPatternFamily(bmiFamily())
        let src = rendered[0].source
        // Test: label first so test_runtime's label picker finds it.
        XCTAssertTrue(src.hasPrefix("# Test: BMI < 18.5 is underweight\n"))
        // Provenance comment on second line.
        XCTAssertTrue(src.contains("Generated from pattern family"))
        XCTAssertTrue(src.contains("[bmi_category]"))
        XCTAssertTrue(src.contains("spec_hash="))
        // Rich feedback shape mirrors Phase 1 templates.
        XCTAssertTrue(src.contains("bmi = 18.49"))
        XCTAssertTrue(src.contains("expected = \"underweight\""))
        XCTAssertTrue(src.contains("student_module.bmi_category(bmi)"))
        XCTAssertTrue(src.contains("input:    bmi={bmi!r}"))
        XCTAssertTrue(src.contains("Hint: values below 18.5"))
        XCTAssertTrue(src.contains("unexpected exception"))
        XCTAssertTrue(src.contains("wrong value"))
    }

    func testRendererUsesDefaultHintWhenCaseHintIsMissing() {
        let family = PatternFamily(
            id: "h", name: "h", kind: .boundaryEquality,
            functionName: "f", paramNames: ["x"],
            defaults: PatternDefaults(hint: "default hint"),
            cases: [
                PatternCase(key: "01", label: "a", args: [.int(1)], expected: .int(1)),
                PatternCase(
                    key: "02", label: "b", args: [.int(2)], expected: .int(2),
                    hint: "override hint"),
            ]
        )
        let rendered = renderPatternFamily(family)
        XCTAssertTrue(rendered[0].source.contains("Hint: default hint"))
        XCTAssertTrue(rendered[1].source.contains("Hint: override hint"))
    }

    func testRendererDisplayNameMatchesCaseLabel() {
        let rendered = renderPatternFamily(bmiFamily())
        XCTAssertEqual(rendered[0].displayName, "BMI < 18.5 is underweight")
    }

    func testSpecHashChangesWithSpecAndIsStableOtherwise() {
        let a = bmiFamily()
        let aHash = patternFamilySpecHash(a)
        XCTAssertEqual(aHash, patternFamilySpecHash(bmiFamily()), "Hash must be stable")
        let b = bmiFamily(id: "bmi_category_v2")
        XCTAssertNotEqual(aHash, patternFamilySpecHash(b))
        let c = bmiFamily(hint: "different hint")
        XCTAssertNotEqual(aHash, patternFamilySpecHash(c))
    }

    func testRenderedSourceIsValidPythonSyntax() throws {
        // ast.parse rejects syntactically invalid Python, catches
        // quote-escape mishaps in the renderer.
        let rendered = renderPatternFamily(bmiFamily())
        for generated in rendered {
            try assertValidPythonSyntax(generated.source, label: generated.filename)
        }
    }

    // MARK: - v0.4.94 — default-valued parameters (argsProvided)

    /// When a case leaves a defaulted param empty (`argsProvided[i] == false`),
    /// the generated Python must:
    ///   1. NOT declare a variable for that param (Python's own default is used)
    ///   2. Call the function positionally while the leading run is contiguous,
    ///      switch to kwargs the moment an arg is omitted.
    /// Regression guard for the "every arg required" pre-v0.4.94 behaviour
    /// and the user-reported `def f(dob: str, currentDate: str = "...")` case.
    func testRenderer_defaultedTrailingArgOmitted_positionalCall() throws {
        let family = PatternFamily(
            id: "dobcheck", name: "DOB Check", kind: .boundaryEquality,
            functionName: "check_dob", paramNames: ["dob", "currentDate"],
            defaults: PatternDefaults(tier: .pub, points: 1),
            cases: [
                PatternCase(
                    key: "01", label: "default currentDate",
                    args: [.string("20260422"), .null],
                    expected: .bool(true),
                    argsProvided: [true, false]
                )
            ]
        )
        let rendered = renderPatternFamily(family)
        XCTAssertEqual(rendered.count, 1)
        let src = rendered[0].source

        XCTAssertTrue(
            src.contains("dob = \"20260422\""),
            "Provided arg must be declared: \(src)")
        XCTAssertFalse(
            src.contains("currentDate ="),
            "Omitted defaulted arg must NOT be declared: \(src)")
        XCTAssertTrue(
            src.contains("check_dob(dob)"),
            "Call should be positional over the leading run: \(src)")
        XCTAssertFalse(
            src.contains("check_dob(dob, currentDate)"),
            "Call must not reference an undeclared local: \(src)")
        try assertValidPythonSyntax(src, label: rendered[0].filename)
    }

    /// Middle-arg omission must switch subsequent provided args to kwargs,
    /// otherwise Python rejects the call as "positional after keyword".
    func testRenderer_defaultedMiddleArgOmitted_usesKwargs() throws {
        let family = PatternFamily(
            id: "middlemissing", name: "Middle missing", kind: .boundaryEquality,
            functionName: "three_args", paramNames: ["a", "b", "c"],
            defaults: PatternDefaults(tier: .pub, points: 1),
            cases: [
                PatternCase(
                    key: "01", label: "skip middle",
                    args: [.int(1), .null, .int(3)],
                    expected: .int(4),
                    argsProvided: [true, false, true]
                )
            ]
        )
        let rendered = renderPatternFamily(family)
        let src = rendered[0].source
        XCTAssertTrue(
            src.contains("three_args(a, c=c)"),
            "Expected kwarg form after middle gap: \(src)")
        XCTAssertFalse(
            src.contains("b ="),
            "Omitted middle arg must not be declared: \(src)")
        try assertValidPythonSyntax(src, label: rendered[0].filename)
    }

    /// Pre-v0.4.94 families have no `argsProvided` array in their spec.
    /// The decoder lands them with an empty `argsProvided`, and the
    /// renderer must treat that as "all args provided" — same output as
    /// before.  No behaviour change for existing families.
    func testRenderer_emptyArgsProvided_behavesAsAllProvided() throws {
        let rendered = renderPatternFamily(bmiFamily())
        let src = rendered[0].source
        XCTAssertTrue(src.contains("bmi = 18.49"))
        XCTAssertTrue(src.contains("bmi_category(bmi)"))
    }

    // MARK: - v0.4.94 — family variables

    /// A family with one dict variable: the rendered test prepends the
    /// assignment, and a case referencing the variable via argVarRefs
    /// emits the bare identifier (no literal) in the param declaration.
    func testRenderer_familyVariable_prependedAndReferencedInCase() throws {
        let patients: JSONValue = .object([
            "p01": .object(["dob": .string("20000101"), "exempt": .bool(false)]),
            "p02": .object(["dob": .string("19950515"), "exempt": .bool(true)]),
        ])
        let family = PatternFamily(
            id: "lookup", name: "Patient lookup", kind: .boundaryEquality,
            functionName: "lookup", paramNames: ["db", "pid"],
            defaults: PatternDefaults(tier: .pub, points: 1),
            cases: [
                PatternCase(
                    key: "01", label: "known patient",
                    args: [.null, .string("p01")],
                    expected: .string("20000101"),
                    argsProvided: [true, true],
                    argVarRefs: ["patients", nil]
                )
            ],
            variables: [FamilyVariable(name: "patients", value: patients)]
        )
        let rendered = renderPatternFamily(family)
        XCTAssertEqual(rendered.count, 1)
        let src = rendered[0].source

        XCTAssertTrue(
            src.contains("patients = {"),
            "Family variable must be declared at module scope: \(src)")
        XCTAssertTrue(
            src.contains("db = patients"),
            "Arg cell $ref must emit a bare identifier assignment: \(src)")
        XCTAssertTrue(
            src.contains("pid = \"p01\""),
            "Literal arg must still render as a literal: \(src)")
        XCTAssertTrue(
            src.contains("lookup(db, pid)"),
            "Call site must use the declared param names: \(src)")
        try assertValidPythonSyntax(src, label: rendered[0].filename)
    }

    /// The validator rejects a case arg that references a variable name
    /// the family doesn't declare.  Prevents dangling `$foo` refs from
    /// sneaking into generated Python as a NameError.
    func testValidation_rejectsUnknownVariableReference() {
        let family = PatternFamily(
            id: "f", name: "f", kind: .boundaryEquality,
            functionName: "f", paramNames: ["x"],
            cases: [
                PatternCase(
                    key: "01", label: "case",
                    args: [.null], expected: .int(0),
                    argsProvided: [true],
                    argVarRefs: ["does_not_exist"]
                )
            ],
            variables: []
        )
        XCTAssertThrowsError(try validatePatternFamilies([family], testSuites: [])) { err in
            let msg = "\(err)"
            XCTAssertTrue(
                msg.contains("does_not_exist") && msg.contains("unknown"),
                "Expected unknown-var error, got: \(msg)")
        }
    }

    /// Variable names must be valid Python identifiers + not collide with
    /// any param name (otherwise the generated test would shadow the
    /// variable when it assigns the per-case arg).
    func testValidation_rejectsVariableCollidingWithParamName() {
        let family = PatternFamily(
            id: "f", name: "f", kind: .boundaryEquality,
            functionName: "f", paramNames: ["x"],
            cases: [
                PatternCase(key: "01", label: "case", args: [.int(1)], expected: .int(1))
            ],
            variables: [FamilyVariable(name: "x", value: .int(99))]
        )
        XCTAssertThrowsError(try validatePatternFamilies([family], testSuites: [])) { err in
            XCTAssertTrue(
                "\(err)".contains("collides with a parameter name"),
                "Expected collision error, got: \(err)")
        }
    }

    /// Spec-hash must change when the family's variables change so the
    /// regeneration diff flips every generated file — ensuring the
    /// auto-retest loop picks up variable edits.
    func testVariables_affectSpecHash() {
        let base = PatternFamily(
            id: "f", name: "f", kind: .boundaryEquality,
            functionName: "f", paramNames: ["x"],
            cases: [PatternCase(key: "01", label: "a", args: [.int(1)], expected: .int(1))]
        )
        let withVar = PatternFamily(
            id: "f", name: "f", kind: .boundaryEquality,
            functionName: "f", paramNames: ["x"],
            cases: [PatternCase(key: "01", label: "a", args: [.int(1)], expected: .int(1))],
            variables: [FamilyVariable(name: "lookup", value: .object(["k": .int(1)]))]
        )
        XCTAssertNotEqual(
            patternFamilySpecHash(base), patternFamilySpecHash(withVar),
            "Adding a family variable must bust the spec hash")
    }

    // MARK: - Validation

    func testValidation_rejectsDuplicateFamilyID() {
        let f1 = bmiFamily(id: "x")
        let f2 = bmiFamily(id: "x")
        XCTAssertThrowsError(try validatePatternFamilies([f1, f2], testSuites: [])) { err in
            XCTAssertTrue("\(err)".contains("Duplicate pattern family id"))
        }
    }

    func testValidation_rejectsDuplicateCaseKey() {
        var cases = bmiFamily().cases
        cases[1] = PatternCase(
            key: cases[0].key, label: cases[1].label,
            args: cases[1].args, expected: cases[1].expected
        )
        let family = PatternFamily(
            id: "f", name: "f", kind: .boundaryEquality,
            functionName: "foo", paramNames: ["x"], cases: cases
        )
        XCTAssertThrowsError(try validatePatternFamilies([family], testSuites: [])) { err in
            XCTAssertTrue("\(err)".contains("duplicate case key"))
        }
    }

    func testValidation_rejectsInvalidPythonIdentifierForFunction() {
        let family = PatternFamily(
            id: "f", name: "f", kind: .boundaryEquality,
            functionName: "2bad", paramNames: ["x"],
            cases: [PatternCase(key: "01", label: "a", args: [.int(1)], expected: .int(1))]
        )
        XCTAssertThrowsError(try validatePatternFamilies([family], testSuites: []))
    }

    func testValidation_rejectsPythonKeywordAsParameterName() {
        let family = PatternFamily(
            id: "f", name: "f", kind: .boundaryEquality,
            functionName: "foo", paramNames: ["class"],
            cases: [PatternCase(key: "01", label: "a", args: [.int(1)], expected: .int(1))]
        )
        XCTAssertThrowsError(try validatePatternFamilies([family], testSuites: []))
    }

    func testValidation_rejectsArgCountMismatch() {
        let family = PatternFamily(
            id: "f", name: "f", kind: .boundaryEquality,
            functionName: "foo", paramNames: ["x", "y"],
            cases: [PatternCase(key: "01", label: "a", args: [.int(1)], expected: .int(1))]
        )
        XCTAssertThrowsError(try validatePatternFamilies([family], testSuites: [])) { err in
            XCTAssertTrue("\(err)".contains("arg(s) but family declares"))
        }
    }

    func testValidation_rejectsGeneratedFilenameCollisionWithRawScript() {
        let family = bmiFamily()
        let rawClash = TestSuiteEntry(
            tier: .pub,
            script: "publictest_bmi_category_01.py",
            generatedBy: nil
        )
        XCTAssertThrowsError(try validatePatternFamilies([family], testSuites: [rawClash])) { err in
            XCTAssertTrue("\(err)".contains("hand-written script with that name already exists"))
        }
    }

    func testValidation_emptySpecIsValid() {
        XCTAssertNoThrow(try validatePatternFamilies([], testSuites: []))
    }

}
