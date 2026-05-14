// Tests/APITests/PatternFamilyApplyTests.swift
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

final class PatternFamilyApplyTests: PatternFamilyTestCase {

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
        XCTAssertNotEqual(
            before, after,
            "Adding a family must change the manifest bytes so the runner cache key invalidates")

        XCTAssertEqual(
            result.writtenFiles.sorted(),
            [
                "publictest_bmi_category_01.py",
                "publictest_bmi_category_02.py",
                "publictest_bmi_category_03.py",
            ])
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
        XCTAssertTrue(
            afterEntries.contains("publictest_handmade.py"),
            "Raw script must survive")
        XCTAssertTrue(
            afterEntries.contains("publictest_bmi_category_01.py"),
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
        XCTAssertTrue(
            entries.contains("publictest_handmade.py"),
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
        XCTAssertEqual(
            fixture.setup.manifest, manifestBefore,
            "Failed validation must not mutate the manifest")
        XCTAssertEqual(
            Set(listZipEntries(zipPath: fixture.setup.zipPath)), zipEntriesBefore,
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
        XCTAssertEqual(
            Set(followup.dependsOn),
            Set([
                "publictest_bmi_category_01.py",
                "publictest_bmi_category_02.py",
                "publictest_bmi_category_03.py",
            ]), "family:<id> must expand to all enabled generated filenames")
        // No `family:` tokens must survive into the persisted manifest.
        for entry in props.testSuites {
            for dep in entry.dependsOn {
                XCTAssertFalse(
                    dep.hasPrefix("family:"),
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
            XCTAssertEqual(
                g.dependsOn, ["publictest_prereq.py"],
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
            XCTAssertTrue(
                "\(abort.reason)".contains("cycle"),
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

    // MARK: - Editable family points round-trip

    /// When `family.defaults.points` is non-default, every generated
    /// `TestSuiteEntry.points` in the manifest must carry it — this is
    /// how the suite editor's family-row Pts input propagates.
    func testApply_familyDefaultPointsPropagatesToGeneratedEntries() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        var family = bmiFamily()
        family = PatternFamily(
            id: family.id, name: family.name, kind: family.kind,
            functionName: family.functionName, paramNames: family.paramNames,
            defaults: PatternDefaults(tier: .pub, points: 5, hint: family.defaults.hint),
            cases: family.cases
        )
        _ = try await applyPatternFamilies(
            to: fixture.setup, nextFamilies: [family], on: fixture.app.db)
        let props = try decodeManifest(fixture.setup.manifest)
        let generated = props.testSuites.filter { $0.generatedBy != nil }
        XCTAssertEqual(generated.count, 3)
        for entry in generated {
            XCTAssertEqual(
                entry.points, 5,
                "family.defaults.points=5 must propagate to every generated entry")
        }
    }

    // MARK: - Authored order preservation (ordering regression guard)

    /// Given authored `[script_a, family(3 cases), script_b]`, the final
    /// `testSuites` array must be `[script_a, family_01, family_02,
    /// family_03, script_b]` in that exact order.  `topologicallySorted`
    /// must not reorder entries that have no dependencies.  Pins the
    /// invariant that made the v0.4.79 "generated rows render at end"
    /// observation a legacy-manifest issue rather than a new-code bug.
    func testApply_authoredOrderPreservedInManifestAndOutcomes() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        try updateScriptInZip(
            zipPath: fixture.setup.zipPath,
            filename: "publictest_a.py", content: "passed('a')\n"
        )
        try updateScriptInZip(
            zipPath: fixture.setup.zipPath,
            filename: "publictest_b.py", content: "passed('b')\n"
        )
        let a = AuthoredRawScript(
            script: "publictest_a.py", tier: .pub, points: 1,
            displayName: nil, dependsOn: []
        )
        let b = AuthoredRawScript(
            script: "publictest_b.py", tier: .pub, points: 1,
            displayName: nil, dependsOn: []
        )
        _ = try await applyPatternFamilies(
            to: fixture.setup,
            nextFamilies: [bmiFamily()],
            authoredItems: [.script(a), .family(id: "bmi_category"), .script(b)],
            on: fixture.app.db
        )
        let props = try decodeManifest(fixture.setup.manifest)
        XCTAssertEqual(
            props.testSuites.map(\.script),
            [
                "publictest_a.py",
                "publictest_bmi_category_01.py",
                "publictest_bmi_category_02.py",
                "publictest_bmi_category_03.py",
                "publictest_b.py",
            ])
    }

    /// Regression guard for the v0.4.95 "family results render at the end
    /// instead of in-line" bug.  Before the fix, `topologicallySorted` was
    /// a FIFO Kahn that let trailing no-dep scripts "cut in line" ahead of
    /// a family that the author had positioned *right* after its prereq —
    /// because the family's generated entries re-enter the queue AFTER
    /// every no-dep node already in it.  With authored-position priority,
    /// the family stays next to its prerequisite, matching what the
    /// instructor saw in the suite editor.
    func testApply_familyWithDependencyStaysInlineAfterPrereq() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        try updateScriptInZip(
            zipPath: fixture.setup.zipPath,
            filename: "publictest_prereq.py", content: "passed('prereq')\n"
        )
        try updateScriptInZip(
            zipPath: fixture.setup.zipPath,
            filename: "publictest_tail.py", content: "passed('tail')\n"
        )
        let prereq = AuthoredRawScript(
            script: "publictest_prereq.py", tier: .pub, points: 1,
            displayName: nil, dependsOn: []
        )
        let tail = AuthoredRawScript(
            script: "publictest_tail.py", tier: .pub, points: 1,
            displayName: nil, dependsOn: []
        )
        let familyWithDep = PatternFamily(
            id: "bmi_category", name: "BMI Category Boundaries",
            kind: .boundaryEquality, functionName: "bmi_category",
            paramNames: ["bmi"],
            defaults: PatternDefaults(hint: "values below 18.5 should be 'underweight'"),
            cases: bmiFamily().cases,
            dependsOn: ["publictest_prereq.py"]
        )

        _ = try await applyPatternFamilies(
            to: fixture.setup,
            nextFamilies: [familyWithDep],
            authoredItems: [
                .script(prereq),
                .family(id: familyWithDep.id),
                .script(tail),
            ],
            on: fixture.app.db
        )

        let props = try decodeManifest(fixture.setup.manifest)
        XCTAssertEqual(
            props.testSuites.map(\.script),
            [
                "publictest_prereq.py",
                "publictest_bmi_category_01.py",
                "publictest_bmi_category_02.py",
                "publictest_bmi_category_03.py",
                "publictest_tail.py",
            ], "Family-with-dep must render in-line with its prerequisite, not pushed to the end of the suite.")
    }

    /// The `PUT /families` path invokes `applyPatternFamilies` with
    /// `authoredItems == nil` (the legacy branch).  When the family
    /// already has generated entries in the existing manifest, the legacy
    /// branch must keep the family anchored at its first-generated-entry
    /// position and must NOT dump it at the end of the suite.  Regression
    /// guard for v0.4.81's position-preservation fix and for the "family
    /// gets pushed to bottom when I edit its cases" user-reported bug.
    func testApply_editingExistingFamilyPreservesMiddlePosition() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        try updateScriptInZip(
            zipPath: fixture.setup.zipPath,
            filename: "publictest_a.py", content: "passed('a')\n"
        )
        try updateScriptInZip(
            zipPath: fixture.setup.zipPath,
            filename: "publictest_b.py", content: "passed('b')\n"
        )
        let a = AuthoredRawScript(
            script: "publictest_a.py", tier: .pub, points: 1,
            displayName: nil, dependsOn: []
        )
        let b = AuthoredRawScript(
            script: "publictest_b.py", tier: .pub, points: 1,
            displayName: nil, dependsOn: []
        )
        // Seed: publish with family in the middle via explicit authoredItems.
        _ = try await applyPatternFamilies(
            to: fixture.setup,
            nextFamilies: [bmiFamily()],
            authoredItems: [.script(a), .family(id: "bmi_category"), .script(b)],
            on: fixture.app.db
        )

        // Now simulate `PUT /families` editing the family: mutate case 02
        // to have a different expected value and re-apply *without*
        // authoredItems (that's how the family-editor modal save wires up).
        var edited = bmiFamily().cases
        edited[1] = PatternCase(
            key: edited[1].key, label: edited[1].label,
            args: edited[1].args, expected: .string("normal (edited)")
        )
        let editedFamily = PatternFamily(
            id: "bmi_category", name: "BMI Category Boundaries",
            kind: .boundaryEquality, functionName: "bmi_category",
            paramNames: ["bmi"],
            defaults: PatternDefaults(
                tier: .pub, points: 1,
                hint: "values below 18.5 should be 'underweight'"),
            cases: edited
        )
        _ = try await applyPatternFamilies(
            to: fixture.setup,
            nextFamilies: [editedFamily],
            authoredItems: nil,
            on: fixture.app.db
        )

        let props = try decodeManifest(fixture.setup.manifest)
        XCTAssertEqual(
            props.testSuites.map(\.script),
            [
                "publictest_a.py",
                "publictest_bmi_category_01.py",
                "publictest_bmi_category_02.py",
                "publictest_bmi_category_03.py",
                "publictest_b.py",
            ],
            "Editing a family's cases via the PUT /families legacy path must keep the family at its original middle position — not push it to the end of the suite."
        )
    }

    /// The Create-page publish flow (`saveNewAssignment`) rebuilds the
    /// manifest from the form's raw-script list (no generated entries)
    /// and then re-runs `applyPatternFamilies` to regenerate them.
    /// Without passing `authoredItems`, the legacy branch sees no
    /// generatedBy markers and dumps every family at the end of the
    /// suite — which cascades into the submission view showing every
    /// family's test outcomes at the bottom.  This exercise the helper
    /// that reconstructs authoredItems from the draft's original
    /// manifest so family positions survive publish.
    func testApply_createPublishPreservesFamilyPosition() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        try updateScriptInZip(
            zipPath: fixture.setup.zipPath,
            filename: "publictest_a.py", content: "passed('a')\n"
        )
        try updateScriptInZip(
            zipPath: fixture.setup.zipPath,
            filename: "publictest_b.py", content: "passed('b')\n"
        )
        let a = AuthoredRawScript(
            script: "publictest_a.py", tier: .pub, points: 1,
            displayName: nil, dependsOn: []
        )
        let b = AuthoredRawScript(
            script: "publictest_b.py", tier: .pub, points: 1,
            displayName: nil, dependsOn: []
        )
        // Draft state: family positioned in the middle.
        _ = try await applyPatternFamilies(
            to: fixture.setup,
            nextFamilies: [bmiFamily()],
            authoredItems: [.script(a), .family(id: "bmi_category"), .script(b)],
            on: fixture.app.db
        )
        let draftProps = try decodeManifest(fixture.setup.manifest)

        // Simulate `saveNewAssignment`'s manifest rebuild: strip
        // generated entries, keep raw entries only.
        let newRawEntries: [ConfiguredSuiteEntry] = [
            ConfiguredSuiteEntry(
                script: "publictest_a.py", tier: "public",
                order: 1, dependsOn: [], points: 1, displayName: nil),
            ConfiguredSuiteEntry(
                script: "publictest_b.py", tier: "public",
                order: 2, dependsOn: [], points: 1, displayName: nil),
        ]
        fixture.setup.manifest = try makeWorkerManifestJSON(
            testSuites: newRawEntries, includeMakefile: false,
            patternFamilies: draftProps.patternFamilies
        )
        try await fixture.setup.save(on: fixture.app.db)

        // Re-apply with authoredItems reconstructed from the draft
        // manifest — this is the publish-path fix.
        let authored = authoredSuiteItemsFromDraftManifest(
            draftProps: draftProps,
            newRawEntries: newRawEntries
        )
        _ = try await applyPatternFamilies(
            to: fixture.setup,
            nextFamilies: draftProps.patternFamilies,
            authoredItems: authored,
            on: fixture.app.db
        )

        let props = try decodeManifest(fixture.setup.manifest)
        XCTAssertEqual(
            props.testSuites.map(\.script),
            [
                "publictest_a.py",
                "publictest_bmi_category_01.py",
                "publictest_bmi_category_02.py",
                "publictest_bmi_category_03.py",
                "publictest_b.py",
            ],
            "Create-publish must preserve the draft's family position; otherwise every published family ends up at the bottom."
        )
    }

}
