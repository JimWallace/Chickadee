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

@testable import APIServer

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
        // Hints are no longer baked into the generated script (v0.4.229) —
        // they're surfaced as a "💡 Hint" display callout instead.
        #expect(!src.contains("Hint:"))
        #expect(src.contains("unexpected exception"))
        #expect(src.contains("wrong value"))
    }

    // v0.4.229: hints (case override + family default) are no longer baked
    // into the generated Python.  They're carried on the spec and surfaced as
    // a "💡 Hint" display callout (the case/default resolution is exercised by
    // `HintSurfacingTests.buildHintByFilename`).  The generated source must
    // contain no hint text regardless of where the hint was authored.
    @Test func rendererDoesNotBakeHintsIntoSource() throws {
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
        #expect(!rendered[0].source.contains("Hint:"))
        #expect(!rendered[0].source.contains("default hint"))
        #expect(!rendered[1].source.contains("Hint:"))
        #expect(!rendered[1].source.contains("override hint"))
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

    // MARK: - Personalization (per-student inputs, #461)

    private func perStudentBoundaryFamily() -> PatternFamily {
        let c = PatternCase(
            key: "01", label: "Adults", args: [.null], expected: .null,
            argVarRefs: ["patients"], expectedVarRef: "adults_expected")
        return PatternFamily(
            id: "adults", name: "Adults", kind: .boundaryEquality,
            functionName: "countAdults", paramNames: ["patients"], cases: [c])
    }

    @Test func rendererEmitsPerStudentPreambleAndExpectedRef() throws {
        let scripts = renderPatternFamily(
            perStudentBoundaryFamily(), perStudentNames: ["patients", "adults_expected"])
        let src = try #require(scripts.first).source
        // The full generated script (preamble + body) must be valid Python.
        try pfAssertValidPythonSyntax(src, label: "adults_01")
        // Loads per-student inputs by path from the reserved file.
        #expect(src.contains("_ck_inputs.py"))
        #expect(src.contains("spec_from_file_location"))
        // Binds both referenced per-student names from _ck.
        #expect(src.contains(#"patients = _ck["patients"]"#))
        #expect(src.contains(#"adults_expected = _ck["adults_expected"]"#))
        // Fails closed when a value is missing (no seed).
        #expect(src.contains("Personalization input"))
        // Expected is the bare per-student ref, not a baked literal.
        #expect(src.contains("expected = adults_expected"))
        #expect(!src.contains("expected = None"))
        // The arg is passed from the bound name and the function is called.
        #expect(src.contains("patients = patients"))
        #expect(src.contains("student_module.countAdults(patients)"))
    }

    /// Runtime contract (not just ast.parse): the generated preamble must
    /// actually load `_ck_inputs.py`, bind the referenced per-student names,
    /// and grade against them — passing when the student's result matches the
    /// resolved expected, failing when it doesn't, and failing *closed* (no
    /// crash) when the seed (hence `_ck_inputs.py`) is absent.  Exercises the
    /// exact file the worker / browser write, so a renderer/runtime contract
    /// drift on either side is caught here.
    @Test func perStudentScriptGradesAgainstCkInputsAtRuntime() throws {
        let scripts = renderPatternFamily(
            perStudentBoundaryFamily(), perStudentNames: ["patients", "adults_expected"])
        let body = try #require(scripts.first).source

        // Byte-for-byte the shape `RunnerDaemon+JobProcessing` emits: a `_ck`
        // dict of Python literals (here a list of dicts + an int).
        let ckInputs = """
            # Auto-generated per-student grading inputs (issue #461). Do not edit.
            _ck = {
                "adults_expected": 2,
                "patients": [{'age': 40}, {'age': 17}, {'age': 65}],
            }
            """
        let correct = "def countAdults(patients):\n    return sum(1 for p in patients if p['age'] >= 18)"
        let buggy = "def countAdults(patients):\n    return len(patients)"

        // Correct student matches the resolved expected (2 adults) → pass.
        #expect(try pfRunGeneratedCase(body: body, ckInputs: ckInputs, student: correct) == .pass)
        // Buggy student returns 3 → fail.
        #expect(try pfRunGeneratedCase(body: body, ckInputs: ckInputs, student: buggy) == .fail)
        // No `_ck_inputs.py` (no seed resolved) → fail closed, not crash.
        #expect(try pfRunGeneratedCase(body: body, ckInputs: nil, student: correct) == .fail)
    }

    @Test func rendererOmitsPreambleWhenNoPerStudentRefs() throws {
        // A normal family renders unchanged even when the assignment declares
        // per-student names the family doesn't reference.
        let scripts = renderPatternFamily(pfBMIFamily(), perStudentNames: ["patients"])
        let src = try #require(scripts.first).source
        #expect(!src.contains("_ck_inputs.py"))
        #expect(!src.contains("Personalization input"))
        #expect(src.contains("expected = \"underweight\""))
    }

    @Test func validation_acceptsPerStudentArgAndExpectedRefs() throws {
        try validatePatternFamilies(
            [perStudentBoundaryFamily()], testSuites: [],
            perStudentExpressionNames: ["patients", "adults_expected"])
    }

    @Test func validation_rejectsUnknownExpectedRef() throws {
        let c = PatternCase(
            key: "01", label: "Adults", args: [.int(1)], expected: .null,
            expectedVarRef: "not_declared")
        let family = PatternFamily(
            id: "adults", name: "Adults", kind: .boundaryEquality,
            functionName: "countAdults", paramNames: ["x"], cases: [c])
        #expect {
            try validatePatternFamilies(
                [family], testSuites: [], perStudentExpressionNames: ["patients"])
        } throws: { error in
            #expect("\(error)".contains("must name a per-student input"))
            return true
        }
    }

    @Test func validation_rejectsPerStudentRefOnUnsupportedKind() throws {
        // performance_threshold has no personalization preamble, so a per-student
        // arg ref is still rejected (boundary + approximate are the supported set).
        let c = PatternCase(
            key: "01", label: "X", args: [.null], expected: .double(100.0),
            argVarRefs: ["patients"])
        let family = PatternFamily(
            id: "perf", name: "Perf", kind: .performanceThreshold,
            functionName: "f", paramNames: ["patients"], cases: [c])
        #expect {
            try validatePatternFamilies(
                [family], testSuites: [], perStudentExpressionNames: ["patients"])
        } throws: { error in
            #expect("\(error)".contains("only supported in boundary_equality and approximate_equality"))
            return true
        }
    }

    // MARK: - Personalization for approximateEquality (Slice E)

    private func perStudentApproxFamily() -> PatternFamily {
        let c = PatternCase(
            key: "01", label: "Average", args: [.null], expected: .null,
            argVarRefs: ["patients"], expectedVarRef: "avg_expected")
        return PatternFamily(
            id: "avg", name: "Average Age", kind: .approximateEquality,
            functionName: "averageAge", paramNames: ["patients"], cases: [c])
    }

    @Test func validation_acceptsPerStudentRefsForApproximate() throws {
        try validatePatternFamilies(
            [perStudentApproxFamily()], testSuites: [],
            perStudentExpressionNames: ["patients", "avg_expected"])
    }

    @Test func approximateRendererEmitsPerStudentPreambleAndExpectedRef() throws {
        let scripts = renderPatternFamily(
            perStudentApproxFamily(), perStudentNames: ["patients", "avg_expected"])
        let src = try #require(scripts.first).source
        try pfAssertValidPythonSyntax(src, label: "avg_01")
        #expect(src.contains("_ck_inputs.py"))
        #expect(src.contains(#"patients = _ck["patients"]"#))
        #expect(src.contains(#"avg_expected = _ck["avg_expected"]"#))
        // Expected is the bare per-student ref, not a baked literal; tolerance kept.
        #expect(src.contains("expected = avg_expected"))
        #expect(src.contains("tolerance ="))
        #expect(src.contains("student_module.averageAge(patients)"))
    }

    @Test func approximateRendererOmitsPreambleWhenNoPerStudentRefs() throws {
        // A normal approximate family with a literal expected renders unchanged
        // (no preamble) even when the assignment declares per-student names.
        let c = PatternCase(key: "01", label: "x", args: [.double(2.0)], expected: .double(4.0))
        let family = PatternFamily(
            id: "sq", name: "Square", kind: .approximateEquality,
            functionName: "square", paramNames: ["x"], cases: [c])
        let src = try #require(renderPatternFamily(family, perStudentNames: ["patients"]).first).source
        #expect(!src.contains("_ck_inputs.py"))
        #expect(src.contains("expected = 4.0"))
    }

    @Test func perStudentApproxGradesAgainstCkInputsAtRuntime() throws {
        let scripts = renderPatternFamily(
            perStudentApproxFamily(), perStudentNames: ["patients", "avg_expected"])
        let body = try #require(scripts.first).source
        let ckInputs = """
            # Auto-generated per-student grading inputs (issue #461). Do not edit.
            _ck = {
                "avg_expected": 40.0,
                "patients": [{'age': 40}, {'age': 20}, {'age': 60}],
            }
            """
        let correct = "def averageAge(patients):\n    return sum(p['age'] for p in patients) / len(patients)"
        let buggy = "def averageAge(patients):\n    return sum(p['age'] for p in patients)"
        #expect(try pfRunGeneratedCase(body: body, ckInputs: ckInputs, student: correct) == .pass)
        #expect(try pfRunGeneratedCase(body: body, ckInputs: ckInputs, student: buggy) == .fail)
        #expect(try pfRunGeneratedCase(body: body, ckInputs: nil, student: correct) == .fail)
    }

    // MARK: - unorderedEquality (Slice F)

    private func unorderedFamily() -> PatternFamily {
        let c = PatternCase(
            key: "01", label: "Pick", args: [.array([.int(3), .int(1), .int(2)])],
            expected: .array([.int(1), .int(2), .int(3)]))
        return PatternFamily(
            id: "pick", name: "Pick", kind: .unorderedEquality,
            functionName: "pick", paramNames: ["xs"], cases: [c])
    }

    private func unorderedPerStudentFamily() -> PatternFamily {
        let c = PatternCase(
            key: "01", label: "Find", args: [.null], expected: .null,
            argVarRefs: ["patients"], expectedVarRef: "matches")
        return PatternFamily(
            id: "find", name: "Find", kind: .unorderedEquality,
            functionName: "findByDiag", paramNames: ["patients"], cases: [c])
    }

    @Test func unorderedRendererEmitsCanonicalComparison() throws {
        let src = try #require(renderPatternFamily(unorderedFamily(), perStudentNames: []).first).source
        try pfAssertValidPythonSyntax(src, label: "pick_01")
        #expect(src.contains("_ck_canon"))
        #expect(src.contains("sort_keys=True"))
        #expect(src.contains("student_module.pick("))
    }

    @Test func unorderedGradesOrderInsensitivelyAtRuntime() throws {
        let body = try #require(renderPatternFamily(unorderedFamily(), perStudentNames: []).first).source
        // Same elements, original (different) order → pass: order is ignored.
        let reordered = "def pick(xs):\n    return list(xs)"
        let sortedFn = "def pick(xs):\n    return sorted(xs)"
        let missing = "def pick(xs):\n    return xs[:2]"
        let notList = "def pick(xs):\n    return 5"
        #expect(try pfRunGeneratedCase(body: body, ckInputs: nil, student: reordered) == .pass)
        #expect(try pfRunGeneratedCase(body: body, ckInputs: nil, student: sortedFn) == .pass)
        #expect(try pfRunGeneratedCase(body: body, ckInputs: nil, student: missing) == .fail)
        #expect(try pfRunGeneratedCase(body: body, ckInputs: nil, student: notList) == .fail)
    }

    @Test func unorderedPerStudentGradesAtRuntime() throws {
        let scripts = renderPatternFamily(
            unorderedPerStudentFamily(), perStudentNames: ["patients", "matches"])
        let body = try #require(scripts.first).source
        // `matches` lists the two 'A' patients in a different order than the
        // student's filter will produce — order-insensitive compare → pass.
        let ckInputs = """
            _ck = {
                "patients": [{'mrn': '1', 'dx': 'A'}, {'mrn': '2', 'dx': 'B'}, {'mrn': '3', 'dx': 'A'}],
                "matches": [{'mrn': '3', 'dx': 'A'}, {'mrn': '1', 'dx': 'A'}],
            }
            """
        let correct = "def findByDiag(patients):\n    return [p for p in patients if p['dx'] == 'A']"
        let buggy = "def findByDiag(patients):\n    return patients"
        #expect(try pfRunGeneratedCase(body: body, ckInputs: ckInputs, student: correct) == .pass)
        #expect(try pfRunGeneratedCase(body: body, ckInputs: ckInputs, student: buggy) == .fail)
        #expect(try pfRunGeneratedCase(body: body, ckInputs: nil, student: correct) == .fail)
    }

    @Test func validation_unorderedRequiresListExpected() throws {
        let c = PatternCase(key: "01", label: "x", args: [.int(1)], expected: .int(5))
        let family = PatternFamily(
            id: "u", name: "U", kind: .unorderedEquality,
            functionName: "f", paramNames: ["x"], cases: [c])
        #expect {
            try validatePatternFamilies([family], testSuites: [])
        } throws: { error in
            #expect("\(error)".contains("must be a list"))
            return true
        }
    }

    @Test func validation_acceptsPerStudentRefsForUnordered() throws {
        try validatePatternFamilies(
            [unorderedPerStudentFamily()], testSuites: [],
            perStudentExpressionNames: ["patients", "matches"])
    }

}
