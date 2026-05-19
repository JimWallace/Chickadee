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
import Testing
import Vapor

@testable import chickadee_server

@Suite struct PatternFamilyRendererTests {

    // MARK: - JSONValue

    @Test func jSONValueRoundTripForEachVariant() throws {
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
            #expect(sample == back, "round-trip mismatch for \(sample)")
        }
    }

    @Test func jSONValuePythonLiteralForScalars() throws {
        #expect(JSONValue.null.pythonLiteral == "None")
        #expect(JSONValue.bool(true).pythonLiteral == "True")
        #expect(JSONValue.bool(false).pythonLiteral == "False")
        #expect(JSONValue.int(42).pythonLiteral == "42")
        #expect(JSONValue.double(18.49).pythonLiteral == "18.49")
        #expect(JSONValue.string("hi").pythonLiteral == "\"hi\"")
        #expect(JSONValue.string("a\"b").pythonLiteral == "\"a\\\"b\"")
        #expect(JSONValue.string("line\nbreak").pythonLiteral == "\"line\\nbreak\"")
    }

    @Test func jSONValuePythonLiteralForArraysAndObjects() throws {
        #expect(JSONValue.array([.int(1), .int(2), .int(3)]).pythonLiteral == "[1, 2, 3]")
        #expect(
            JSONValue.object(["b": .int(2), "a": .int(1)]).pythonLiteral == #"{"a": 1, "b": 2}"#,
            "Object keys must be emitted in sorted order for determinism")
    }

    // MARK: - Renderer

    @Test func rendererIsDeterministic() throws {
        let family = pfBMIFamily()
        let first = renderPatternFamily(family)
        let second = renderPatternFamily(family)
        #expect(first == second, "Same input must produce byte-identical output")
    }

    @Test func rendererSkipsDisabledCases() throws {
        var cases = pfBMIFamily().cases
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
        #expect(rendered.count == 2)
        #expect(rendered.map(\.caseKey).contains(cases[1].key) == false)
    }

    @Test func rendererFilenameFormat() throws {
        let rendered = renderPatternFamily(pfBMIFamily())
        #expect(rendered[0].filename == "publictest_bmi_category_01.py")
        #expect(rendered[1].filename == "publictest_bmi_category_02.py")
        #expect(rendered[2].filename == "publictest_bmi_category_03.py")
    }

    @Test func rendererPerCaseTierOverrideDrivesFilenamePrefix() throws {
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
        #expect(rendered[0].filename == "publictest_mix_a.py")
        #expect(rendered[1].filename == "secrettest_mix_b.py")
    }

    @Test func rendererSourceContainsRichFeedbackElements() throws {
        let rendered = renderPatternFamily(pfBMIFamily())
        let src = rendered[0].source
        // Test: label first so test_runtime's label picker finds it.
        #expect(src.hasPrefix("# Test: BMI < 18.5 is underweight\n"))
        // Provenance comment on second line.
        #expect(src.contains("Generated from pattern family"))
        #expect(src.contains("[bmi_category]"))
        #expect(src.contains("spec_hash="))
        // Rich feedback shape mirrors Phase 1 templates.
        #expect(src.contains("bmi = 18.49"))
        #expect(src.contains("expected = \"underweight\""))
        #expect(src.contains("student_module.bmi_category(bmi)"))
        #expect(src.contains("input:    bmi={bmi!r}"))
        #expect(src.contains("Hint: values below 18.5"))
        #expect(src.contains("unexpected exception"))
        #expect(src.contains("wrong value"))
    }

    @Test func rendererUsesDefaultHintWhenCaseHintIsMissing() throws {
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
        #expect(rendered[0].source.contains("Hint: default hint"))
        #expect(rendered[1].source.contains("Hint: override hint"))
    }

    @Test func rendererDisplayNameMatchesCaseLabel() throws {
        let rendered = renderPatternFamily(pfBMIFamily())
        #expect(rendered[0].displayName == "BMI < 18.5 is underweight")
    }

    @Test func specHashChangesWithSpecAndIsStableOtherwise() throws {
        let a = pfBMIFamily()
        let aHash = patternFamilySpecHash(a)
        #expect(aHash == patternFamilySpecHash(pfBMIFamily()), "Hash must be stable")
        let b = pfBMIFamily(id: "bmi_category_v2")
        #expect(aHash != patternFamilySpecHash(b))
        let c = pfBMIFamily(hint: "different hint")
        #expect(aHash != patternFamilySpecHash(c))
    }

    @Test func renderedSourceIsValidPythonSyntax() throws {
        // ast.parse rejects syntactically invalid Python, catches
        // quote-escape mishaps in the renderer.
        let rendered = renderPatternFamily(pfBMIFamily())
        for generated in rendered {
            try pfAssertValidPythonSyntax(generated.source, label: generated.filename)
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
    @Test func renderer_defaultedTrailingArgOmitted_positionalCall() throws {
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
        #expect(rendered.count == 1)
        let src = rendered[0].source

        #expect(
            src.contains("dob = \"20260422\""),
            "Provided arg must be declared: \(src)")
        #expect(src.contains("currentDate =") == false, "Omitted defaulted arg must NOT be declared: \(src)")
        #expect(
            src.contains("check_dob(dob)"),
            "Call should be positional over the leading run: \(src)")
        #expect(
            src.contains("check_dob(dob, currentDate)") == false, "Call must not reference an undeclared local: \(src)")
        try pfAssertValidPythonSyntax(src, label: rendered[0].filename)
    }

    /// Middle-arg omission must switch subsequent provided args to kwargs,
    /// otherwise Python rejects the call as "positional after keyword".
    @Test func renderer_defaultedMiddleArgOmitted_usesKwargs() throws {
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
        #expect(
            src.contains("three_args(a, c=c)"),
            "Expected kwarg form after middle gap: \(src)")
        #expect(src.contains("b =") == false, "Omitted middle arg must not be declared: \(src)")
        try pfAssertValidPythonSyntax(src, label: rendered[0].filename)
    }

    /// Pre-v0.4.94 families have no `argsProvided` array in their spec.
    /// The decoder lands them with an empty `argsProvided`, and the
    /// renderer must treat that as "all args provided" — same output as
    /// before.  No behaviour change for existing families.
    @Test func renderer_emptyArgsProvided_behavesAsAllProvided() throws {
        let rendered = renderPatternFamily(pfBMIFamily())
        let src = rendered[0].source
        #expect(src.contains("bmi = 18.49"))
        #expect(src.contains("bmi_category(bmi)"))
    }

    // MARK: - v0.4.94 — family variables

    /// A family with one dict variable: the rendered test prepends the
    /// assignment, and a case referencing the variable via argVarRefs
    /// emits the bare identifier (no literal) in the param declaration.
    @Test func renderer_familyVariable_prependedAndReferencedInCase() throws {
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
        #expect(rendered.count == 1)
        let src = rendered[0].source

        #expect(
            src.contains("patients = {"),
            "Family variable must be declared at module scope: \(src)")
        #expect(
            src.contains("db = patients"),
            "Arg cell $ref must emit a bare identifier assignment: \(src)")
        #expect(
            src.contains("pid = \"p01\""),
            "Literal arg must still render as a literal: \(src)")
        #expect(
            src.contains("lookup(db, pid)"),
            "Call site must use the declared param names: \(src)")
        try pfAssertValidPythonSyntax(src, label: rendered[0].filename)
    }

    /// The validator rejects a case arg that references a variable name
    /// the family doesn't declare.  Prevents dangling `$foo` refs from
    /// sneaking into generated Python as a NameError.
    @Test func validation_rejectsUnknownVariableReference() throws {
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
        #expect { try validatePatternFamilies([family], testSuites: []) } throws: { error in
            let msg = "\(error)"
            #expect(
                msg.contains("does_not_exist") && msg.contains("unknown"),
                "Expected unknown-var erroror, got: \(msg)")

            return true
        }
    }

    /// Variable names must be valid Python identifiers + not collide with
    /// any param name (otherwise the generated test would shadow the
    /// variable when it assigns the per-case arg).
    @Test func validation_rejectsVariableCollidingWithParamName() throws {
        let family = PatternFamily(
            id: "f", name: "f", kind: .boundaryEquality,
            functionName: "f", paramNames: ["x"],
            cases: [
                PatternCase(key: "01", label: "case", args: [.int(1)], expected: .int(1))
            ],
            variables: [FamilyVariable(name: "x", value: .int(99))]
        )
        #expect { try validatePatternFamilies([family], testSuites: []) } throws: { error in
            #expect(
                "\(error)".contains("collides with a parameter name"),
                "Expected collision erroror, got: \(error)")

            return true
        }
    }

    /// Spec-hash must change when the family's variables change so the
    /// regeneration diff flips every generated file — ensuring the
    /// auto-retest loop picks up variable edits.
    @Test func variables_affectSpecHash() throws {
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
        #expect(
            patternFamilySpecHash(base) != patternFamilySpecHash(withVar),
            "Adding a family variable must bust the spec hash")
    }

    // MARK: - Validation

    @Test func validation_rejectsDuplicateFamilyID() throws {
        let f1 = pfBMIFamily(id: "x")
        let f2 = pfBMIFamily(id: "x")
        #expect { try validatePatternFamilies([f1, f2], testSuites: []) } throws: { error in
            #expect("\(error)".contains("Duplicate pattern family id"))

            return true
        }
    }

    @Test func validation_rejectsDuplicateCaseKey() throws {
        var cases = pfBMIFamily().cases
        cases[1] = PatternCase(
            key: cases[0].key, label: cases[1].label,
            args: cases[1].args, expected: cases[1].expected
        )
        let family = PatternFamily(
            id: "f", name: "f", kind: .boundaryEquality,
            functionName: "foo", paramNames: ["x"], cases: cases
        )
        #expect { try validatePatternFamilies([family], testSuites: []) } throws: { error in
            #expect("\(error)".contains("duplicate case key"))

            return true
        }
    }

    @Test func validation_rejectsInvalidPythonIdentifierForFunction() throws {
        let family = PatternFamily(
            id: "f", name: "f", kind: .boundaryEquality,
            functionName: "2bad", paramNames: ["x"],
            cases: [PatternCase(key: "01", label: "a", args: [.int(1)], expected: .int(1))]
        )
        #expect(throws: (any Error).self) { try validatePatternFamilies([family], testSuites: []) }
    }

    @Test func validation_rejectsPythonKeywordAsParameterName() throws {
        let family = PatternFamily(
            id: "f", name: "f", kind: .boundaryEquality,
            functionName: "foo", paramNames: ["class"],
            cases: [PatternCase(key: "01", label: "a", args: [.int(1)], expected: .int(1))]
        )
        #expect(throws: (any Error).self) { try validatePatternFamilies([family], testSuites: []) }
    }

    @Test func validation_rejectsArgCountMismatch() throws {
        let family = PatternFamily(
            id: "f", name: "f", kind: .boundaryEquality,
            functionName: "foo", paramNames: ["x", "y"],
            cases: [PatternCase(key: "01", label: "a", args: [.int(1)], expected: .int(1))]
        )
        #expect { try validatePatternFamilies([family], testSuites: []) } throws: { error in
            #expect("\(error)".contains("arg(s) but family declares"))

            return true
        }
    }

    @Test func validation_rejectsGeneratedFilenameCollisionWithRawScript() throws {
        let family = pfBMIFamily()
        let rawClash = TestSuiteEntry(
            tier: .pub,
            script: "publictest_bmi_category_01.py",
            generatedBy: nil
        )
        #expect { try validatePatternFamilies([family], testSuites: [rawClash]) } throws: { error in
            #expect("\(error)".contains("hand-written script with that name already exists"))

            return true
        }
    }

    @Test func validation_emptySpecIsValid() throws {
        try validatePatternFamilies([], testSuites: [])
    }

}
