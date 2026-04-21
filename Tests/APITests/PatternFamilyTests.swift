// Tests/APITests/PatternFamilyTests.swift
//
// Exercises Phase 2a of the pattern-family feature:
//   - JSONValue round-trip + Python literal rendering
//   - PatternFamilyRenderer determinism and rich-feedback output shape
//   - Validation rules (unique ids/keys, identifier validity, arg count,
//     filename collisions)
//   - applyPatternFamilies mutating the zip and manifest, and the runner
//     cache key (derived from manifest bytes) changing as a result.

import XCTest
@testable import chickadee_server
import Core
import Foundation
import Crypto
import Vapor
import Fluent

final class PatternFamilyTests: XCTestCase {

    // MARK: - Fixtures

    private func bmiFamily(
        id: String = "bmi_category",
        hint: String? = "values below 18.5 should be 'underweight'",
        tier: TestTier = .pub
    ) -> PatternFamily {
        PatternFamily(
            id: id,
            name: "BMI Category Boundaries",
            kind: .boundaryEquality,
            functionName: "bmi_category",
            paramNames: ["bmi"],
            defaults: PatternDefaults(tier: tier, points: 1, hint: hint),
            cases: [
                PatternCase(key: "01", label: "BMI < 18.5 is underweight",
                            args: [.double(18.49)], expected: .string("underweight")),
                PatternCase(key: "02", label: "BMI = 18.5 is normal",
                            args: [.double(18.5)],  expected: .string("normal")),
                PatternCase(key: "03", label: "BMI >= 30 is obese",
                            args: [.double(30.0)],  expected: .string("obese")),
            ]
        )
    }

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
        let first  = renderPatternFamily(family)
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
                PatternCase(key: "a", label: "pub",    args: [.int(1)], expected: .int(1)),
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
                PatternCase(key: "02", label: "b", args: [.int(2)], expected: .int(2),
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

    // MARK: - applyPatternFamilies integration

    func testApply_addFamilyWritesScriptsAndChangesManifestHash() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let before = try manifestCacheMaterial(fixture.setup)

        let result = try await applyPatternFamilies(
            to: fixture.setup,
            nextFamilies: [bmiFamily()],
            on: fixture.app.db
        )

        let after = try manifestCacheMaterial(fixture.setup)
        XCTAssertNotEqual(before, after,
                          "Adding a family must change the manifest bytes so the runner cache key invalidates")

        XCTAssertEqual(result.writtenFiles.sorted(),
                       ["publictest_bmi_category_01.py",
                        "publictest_bmi_category_02.py",
                        "publictest_bmi_category_03.py"])
        XCTAssertEqual(result.deletedFiles, [])

        // Zip actually contains the generated files.
        let entries = Set(listZipEntries(zipPath: fixture.setup.zipPath))
        for f in result.writtenFiles {
            XCTAssertTrue(entries.contains(f), "Zip missing generated file \(f)")
        }

        // Manifest carries the family spec + generatedBy tags on entries.
        let props = try decodeManifest(fixture.setup.manifest)
        XCTAssertEqual(props.patternFamilies.count, 1)
        XCTAssertEqual(props.patternFamilies[0].id, "bmi_category")
        let generatedEntries = props.testSuites.filter { $0.generatedBy != nil }
        XCTAssertEqual(generatedEntries.count, 3)
        for entry in generatedEntries {
            XCTAssertEqual(entry.generatedBy, "bmi_category")
        }
    }

    /// The /edit/save flow rebuilds the zip + manifest from the visible UI
    /// suite rows (which filter out generated scripts) and then re-applies
    /// pattern families.  This test simulates that sequence and verifies that
    /// families survive a zip+manifest rebuild: the family spec persists in
    /// the manifest, generated .py files land back in the zip, and the
    /// manifest's testSuites carry `generatedBy` tags.  Regression guard for
    /// the v0.4.76 bug where families silently vanished on Save.
    func testApply_surviveEditSaveManifestRebuild() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        // Seed: one raw script + one family.
        try updateScriptInZip(
            zipPath: fixture.setup.zipPath,
            filename: "publictest_handmade.py",
            content: "# handmade\npassed('ok')\n"
        )
        let rawEntry = ConfiguredSuiteEntry(
            script: "publictest_handmade.py", tier: "public", order: 1,
            dependsOn: [], points: 1, displayName: nil
        )
        fixture.setup.manifest = try makeWorkerManifestJSON(
            testSuites: [rawEntry], includeMakefile: false
        )
        try await fixture.setup.save(on: fixture.app.db)
        _ = try await applyPatternFamilies(
            to: fixture.setup, nextFamilies: [bmiFamily()], on: fixture.app.db
        )

        // Sanity: both raw + generated present before the rebuild.
        let beforeEntries = Set(listZipEntries(zipPath: fixture.setup.zipPath))
        XCTAssertTrue(beforeEntries.contains("publictest_handmade.py"))
        XCTAssertTrue(beforeEntries.contains("publictest_bmi_category_01.py"))

        // Simulate /edit/save: rewrite the zip from "visible" rows only
        // (raw scripts) — this intentionally drops the generated .py files
        // from the zip, matching what createRunnerSetupZip does.  Then
        // rebuild the manifest forwarding the existing pattern families,
        // and re-apply them to restore generated files.
        let existingFamilies = try decodeManifest(fixture.setup.manifest).patternFamilies
        XCTAssertEqual(existingFamilies.count, 1, "family must survive into the existing manifest")

        // Nuke generated files from the zip (simulating the full zip rewrite).
        for f in patternFamilyAllGeneratedFilenames(existingFamilies[0]) {
            try? removeScriptFromZip(zipPath: fixture.setup.zipPath, filename: f)
        }
        fixture.setup.manifest = try makeWorkerManifestJSON(
            testSuites: [rawEntry], includeMakefile: false,
            patternFamilies: existingFamilies
        )
        try await fixture.setup.save(on: fixture.app.db)

        // Re-apply — this is the fix in saveEditedAssignment.
        _ = try await applyPatternFamilies(
            to: fixture.setup, nextFamilies: existingFamilies, on: fixture.app.db
        )

        // After the simulated save: raw + generated both present, family
        // spec persisted, testSuites entries carry generatedBy tags.
        let afterEntries = Set(listZipEntries(zipPath: fixture.setup.zipPath))
        XCTAssertTrue(afterEntries.contains("publictest_handmade.py"),
                      "Raw script must survive")
        XCTAssertTrue(afterEntries.contains("publictest_bmi_category_01.py"),
                      "Generated script must be restored by applyPatternFamilies")
        XCTAssertTrue(afterEntries.contains("publictest_bmi_category_02.py"))
        XCTAssertTrue(afterEntries.contains("publictest_bmi_category_03.py"))

        let props = try decodeManifest(fixture.setup.manifest)
        XCTAssertEqual(props.patternFamilies.count, 1)
        XCTAssertEqual(props.patternFamilies[0].id, "bmi_category")
        let generatedEntries = props.testSuites.filter { $0.generatedBy != nil }
        XCTAssertEqual(generatedEntries.count, 3)
        // Each generated entry's display name must carry the case label so
        // the student result view shows distinct, labelled test rows.
        let names = Set(generatedEntries.compactMap(\.name))
        XCTAssertTrue(names.contains("BMI < 18.5 is underweight"))
        XCTAssertTrue(names.contains("BMI = 18.5 is normal"))
        XCTAssertTrue(names.contains("BMI >= 30 is obese"))
    }

    func testApply_removingCaseDeletesItsScript() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        _ = try await applyPatternFamilies(
            to: fixture.setup, nextFamilies: [bmiFamily()], on: fixture.app.db)

        // Re-apply with case "02" removed.
        let reduced = PatternFamily(
            id: "bmi_category", name: "BMI Category Boundaries",
            kind: .boundaryEquality, functionName: "bmi_category",
            paramNames: ["bmi"],
            defaults: PatternDefaults(hint: "hint"),
            cases: bmiFamily().cases.filter { $0.key != "02" }
        )

        let result = try await applyPatternFamilies(
            to: fixture.setup, nextFamilies: [reduced], on: fixture.app.db)
        XCTAssertEqual(result.deletedFiles, ["publictest_bmi_category_02.py"])
        let entries = Set(listZipEntries(zipPath: fixture.setup.zipPath))
        XCTAssertFalse(entries.contains("publictest_bmi_category_02.py"))
        XCTAssertTrue(entries.contains("publictest_bmi_category_01.py"))
    }

    func testApply_removingEntireFamilyCleansUpAllItsScripts() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        _ = try await applyPatternFamilies(
            to: fixture.setup, nextFamilies: [bmiFamily()], on: fixture.app.db)

        let result = try await applyPatternFamilies(
            to: fixture.setup, nextFamilies: [], on: fixture.app.db)
        XCTAssertEqual(result.deletedFiles.count, 3)

        let props = try decodeManifest(fixture.setup.manifest)
        XCTAssertEqual(props.patternFamilies, [])
        XCTAssertTrue(props.testSuites.filter { $0.generatedBy != nil }.isEmpty)
    }

    func testApply_preservesHandWrittenScripts() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        // Pre-seed a hand-written script before applying a family.
        try updateScriptInZip(
            zipPath: fixture.setup.zipPath,
            filename: "publictest_handmade.py",
            content: "# handmade\npassed('ok')\n"
        )
        fixture.setup.manifest = updateManifestAddingScript(
            manifestJSON: fixture.setup.manifest,
            entry: ConfiguredSuiteEntry(
                script: "publictest_handmade.py", tier: "public", order: 1,
                dependsOn: [], points: 1, displayName: nil, generatedBy: nil
            )
        )!
        try await fixture.setup.save(on: fixture.app.db)

        _ = try await applyPatternFamilies(
            to: fixture.setup, nextFamilies: [bmiFamily()], on: fixture.app.db)

        let entries = Set(listZipEntries(zipPath: fixture.setup.zipPath))
        XCTAssertTrue(entries.contains("publictest_handmade.py"),
                      "Hand-written scripts must survive a family apply")

        let props = try decodeManifest(fixture.setup.manifest)
        XCTAssertTrue(props.testSuites.contains { $0.script == "publictest_handmade.py" && $0.generatedBy == nil })
    }

    func testApply_rejectsFilenameCollisionAndLeavesSetupUnchanged() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        // Create a hand-written file that will collide with a generated name.
        try updateScriptInZip(
            zipPath: fixture.setup.zipPath,
            filename: "publictest_bmi_category_01.py",
            content: "# handmade clash\npassed('ok')\n"
        )
        fixture.setup.manifest = updateManifestAddingScript(
            manifestJSON: fixture.setup.manifest,
            entry: ConfiguredSuiteEntry(
                script: "publictest_bmi_category_01.py", tier: "public", order: 1,
                dependsOn: [], points: 1, displayName: nil
            )
        )!
        try await fixture.setup.save(on: fixture.app.db)
        let manifestBefore = fixture.setup.manifest
        let zipEntriesBefore = Set(listZipEntries(zipPath: fixture.setup.zipPath))

        do {
            _ = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [bmiFamily()], on: fixture.app.db)
            XCTFail("Expected validation to reject the family")
        } catch let abort as AbortError {
            XCTAssertTrue("\(abort.reason)".contains("hand-written script"))
        }
        XCTAssertEqual(fixture.setup.manifest, manifestBefore,
                       "Failed validation must not mutate the manifest")
        XCTAssertEqual(Set(listZipEntries(zipPath: fixture.setup.zipPath)), zipEntriesBefore,
                       "Failed validation must not mutate the zip")
    }

    // MARK: - family:<id> dependency expansion

    /// When a raw script declares `dependsOn: ["family:bmi_category"]`, the
    /// persisted manifest that reaches the runner must have that token
    /// expanded to the family's actual enabled generated filenames — the
    /// runner has no notion of families.
    func testApply_expandsFamilyRefOnRawScriptDep() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        try updateScriptInZip(
            zipPath: fixture.setup.zipPath,
            filename: "publictest_followup.py",
            content: "# followup\npassed('ok')\n"
        )
        let rawEntry = AuthoredRawScript(
            script: "publictest_followup.py",
            tier: .pub, points: 1, displayName: nil,
            dependsOn: ["family:bmi_category"]
        )
        _ = try await applyPatternFamilies(
            to: fixture.setup,
            nextFamilies: [bmiFamily()],
            authoredItems: [.script(rawEntry), .family(id: "bmi_category")],
            on: fixture.app.db
        )

        let props = try decodeManifest(fixture.setup.manifest)
        let followup = try XCTUnwrap(props.testSuites.first { $0.script == "publictest_followup.py" })
        XCTAssertEqual(Set(followup.dependsOn), Set([
            "publictest_bmi_category_01.py",
            "publictest_bmi_category_02.py",
            "publictest_bmi_category_03.py",
        ]), "family:<id> must expand to all enabled generated filenames")
        // No `family:` tokens must survive into the persisted manifest.
        for entry in props.testSuites {
            for dep in entry.dependsOn {
                XCTAssertFalse(dep.hasPrefix("family:"),
                               "Persisted dep '\(dep)' must be a filename, not a family ref")
            }
        }
    }

    /// Family-level `dependsOn` propagates to every generated case, with
    /// family-ref tokens expanded to the referenced family's filenames.
    func testApply_familyLevelDepsExpandedAndInheritedByCases() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        // Seed a prereq raw script.
        try updateScriptInZip(
            zipPath: fixture.setup.zipPath,
            filename: "publictest_prereq.py",
            content: "# prereq\npassed('ok')\n"
        )
        let prereq = AuthoredRawScript(
            script: "publictest_prereq.py",
            tier: .pub, points: 1, displayName: nil, dependsOn: []
        )
        let family = PatternFamily(
            id: "bmi_category", name: "BMI", kind: .boundaryEquality,
            functionName: "bmi_category", paramNames: ["bmi"],
            defaults: PatternDefaults(hint: "x"),
            cases: bmiFamily().cases,
            dependsOn: ["publictest_prereq.py"]
        )

        _ = try await applyPatternFamilies(
            to: fixture.setup,
            nextFamilies: [family],
            authoredItems: [.script(prereq), .family(id: family.id)],
            on: fixture.app.db
        )

        let props = try decodeManifest(fixture.setup.manifest)
        let generated = props.testSuites.filter { $0.generatedBy != nil }
        XCTAssertEqual(generated.count, 3)
        for g in generated {
            XCTAssertEqual(g.dependsOn, ["publictest_prereq.py"],
                           "Every generated case must inherit the family-level dep")
        }
    }

    /// Removing a family drops `family:<id>` tokens from other entries'
    /// dependsOn — no dangling refs remain.
    func testApply_removingFamilyClearsFamilyRefsFromOtherEntries() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        try updateScriptInZip(
            zipPath: fixture.setup.zipPath,
            filename: "publictest_followup.py",
            content: "# followup\npassed('ok')\n"
        )
        let followup = AuthoredRawScript(
            script: "publictest_followup.py",
            tier: .pub, points: 1, displayName: nil,
            dependsOn: ["family:bmi_category"]
        )
        // First apply with the family present.
        _ = try await applyPatternFamilies(
            to: fixture.setup,
            nextFamilies: [bmiFamily()],
            authoredItems: [.script(followup), .family(id: "bmi_category")],
            on: fixture.app.db
        )
        // Now remove the family: the raw script's dependsOn has to drop the
        // dangling filenames (and since no family remains, expansion emits nothing).
        let followupNoFamilyRef = AuthoredRawScript(
            script: "publictest_followup.py",
            tier: .pub, points: 1, displayName: nil, dependsOn: []
        )
        _ = try await applyPatternFamilies(
            to: fixture.setup,
            nextFamilies: [],
            authoredItems: [.script(followupNoFamilyRef)],
            on: fixture.app.db
        )
        let props = try decodeManifest(fixture.setup.manifest)
        let entry = try XCTUnwrap(props.testSuites.first { $0.script == "publictest_followup.py" })
        XCTAssertEqual(entry.dependsOn, [])
        XCTAssertTrue(props.patternFamilies.isEmpty)
    }

    /// The authored-graph cycle detector rejects script→family→script cycles.
    func testApply_rejectsScriptFamilyScriptCycle() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        try updateScriptInZip(
            zipPath: fixture.setup.zipPath,
            filename: "publictest_a.py", content: "passed('ok')\n"
        )
        // Cycle: a → family:bmi → a
        let a = AuthoredRawScript(
            script: "publictest_a.py",
            tier: .pub, points: 1, displayName: nil,
            dependsOn: ["family:bmi_category"]
        )
        let family = PatternFamily(
            id: "bmi_category", name: "BMI", kind: .boundaryEquality,
            functionName: "bmi_category", paramNames: ["bmi"],
            defaults: PatternDefaults(),
            cases: bmiFamily().cases,
            dependsOn: ["publictest_a.py"]
        )

        do {
            _ = try await applyPatternFamilies(
                to: fixture.setup,
                nextFamilies: [family],
                authoredItems: [.script(a), .family(id: family.id)],
                on: fixture.app.db
            )
            XCTFail("Expected cycle to be rejected")
        } catch let abort as AbortError {
            XCTAssertTrue("\(abort.reason)".contains("cycle"),
                          "Expected cycle error, got: \(abort.reason)")
        }
    }

    /// Family-to-family cycles are rejected too.
    func testApply_rejectsFamilyFamilyCycle() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let fa = PatternFamily(
            id: "fa", name: "fa", kind: .boundaryEquality,
            functionName: "fa", paramNames: ["x"],
            cases: [PatternCase(key: "01", label: "a", args: [.int(1)], expected: .int(1))],
            dependsOn: ["family:fb"]
        )
        let fb = PatternFamily(
            id: "fb", name: "fb", kind: .boundaryEquality,
            functionName: "fb", paramNames: ["x"],
            cases: [PatternCase(key: "01", label: "b", args: [.int(1)], expected: .int(1))],
            dependsOn: ["family:fa"]
        )
        do {
            _ = try await applyPatternFamilies(
                to: fixture.setup,
                nextFamilies: [fa, fb],
                authoredItems: [.family(id: "fa"), .family(id: "fb")],
                on: fixture.app.db
            )
            XCTFail("Expected cycle to be rejected")
        } catch let abort as AbortError {
            XCTAssertTrue("\(abort.reason)".contains("cycle"))
        }
    }

    /// Self-referential families (`family: F depends on family:F`) are rejected.
    func testApply_rejectsSelfReferentialFamily() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let f = PatternFamily(
            id: "loop", name: "loop", kind: .boundaryEquality,
            functionName: "loop", paramNames: ["x"],
            cases: [PatternCase(key: "01", label: "a", args: [.int(1)], expected: .int(1))],
            dependsOn: ["family:loop"]
        )
        do {
            _ = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [f],
                authoredItems: [.family(id: "loop")], on: fixture.app.db)
            XCTFail("Expected self-ref to be rejected")
        } catch let abort as AbortError {
            XCTAssertTrue("\(abort.reason)".contains("itself") || "\(abort.reason)".contains("cycle"))
        }
    }

    /// Referencing a family id that doesn't exist yields a readable error.
    func testApply_rejectsUnknownFamilyRef() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        try updateScriptInZip(
            zipPath: fixture.setup.zipPath,
            filename: "publictest_a.py", content: "passed('ok')\n"
        )
        let a = AuthoredRawScript(
            script: "publictest_a.py",
            tier: .pub, points: 1, displayName: nil,
            dependsOn: ["family:does_not_exist"]
        )
        do {
            _ = try await applyPatternFamilies(
                to: fixture.setup,
                nextFamilies: [],
                authoredItems: [.script(a)],
                on: fixture.app.db
            )
            XCTFail("Expected unknown-family-ref rejection")
        } catch let abort as AbortError {
            XCTAssertTrue("\(abort.reason)".contains("does_not_exist"))
        }
    }

    // MARK: - Fixture plumbing

    private struct Fixture {
        let app: Application
        let setup: APITestSetup
        let cleanup: () -> Void
    }

    private func makeFixture() async throws -> Fixture {
        let app = try await Application.make(.testing)
        try await configureTestDatabase(app)

        let tmpDir = NSTemporaryDirectory() + "pattern-family-tests-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        app.testSetupsDirectory = tmpDir

        let courseID = UUID()
        let course = APICourse(id: courseID, code: "PF101", name: "Pattern Family Test", enrollmentMode: .auto)
        try await course.save(on: app.db)

        let zipPath = tmpDir + "\(UUID().uuidString).zip"
        try writeEmptyZip(at: zipPath)

        let initialManifest = try makeWorkerManifestJSON(
            testSuites: [], includeMakefile: false
        )
        let setup = APITestSetup(
            id: "pf_test_\(UUID().uuidString.prefix(8))",
            manifest: initialManifest, zipPath: zipPath, courseID: courseID
        )
        try await setup.save(on: app.db)

        let appBox = app
        return Fixture(app: app, setup: setup, cleanup: {
            try? FileManager.default.removeItem(atPath: tmpDir)
            Task { try? await appBox.asyncShutdown() }
        })
    }

    private func writeEmptyZip(at path: String) throws {
        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory
            .appendingPathComponent("empty-zip-staging-\(UUID().uuidString)")
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }
        // zip needs at least one entry to produce a valid archive.
        try Data("placeholder".utf8).write(
            to: stagingDir.appendingPathComponent(".placeholder")
        )
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = stagingDir
        zip.arguments = ["-q", "-r", path, "."]
        zip.standardOutput = Pipe()
        zip.standardError = Pipe()
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
    }

    private func manifestCacheMaterial(_ setup: APITestSetup) throws -> String {
        // Mirror the shape the runner uses at RunnerDaemon.swift:1110-1116:
        //   hash(testSetupID + url + manifestBytes)
        // Using manifest bytes alone is enough to prove invalidation here.
        let digest = SHA256.hash(data: Data(setup.manifest.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func decodeManifest(_ json: String) throws -> TestProperties {
        try JSONDecoder().decode(TestProperties.self, from: Data(json.utf8))
    }

    private func assertValidPythonSyntax(_ source: String, label: String,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", "import ast, sys; ast.parse(sys.stdin.read())"]
        let stdin = Pipe(); let stderr = Pipe()
        p.standardInput = stdin
        p.standardError = stderr
        p.standardOutput = Pipe()
        try p.run()
        stdin.fileHandleForWriting.write(Data(source.utf8))
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTFail("Generated source for \(label) is not valid Python:\n\(err)\n--- source ---\n\(source)",
                    file: file, line: line)
        }
    }
}
