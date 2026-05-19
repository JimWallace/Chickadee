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
import Testing
import Vapor

@testable import chickadee_server

@Suite struct PatternFamilyApplyTests {

    // MARK: - applyPatternFamilies integration

    @Test func apply_addFamilyWritesScriptsAndChangesManifestHash() async throws {
        try await withPatternFamilyFixture { fixture in

            let before = try pfManifestCacheMaterial(fixture.setup)

            let result = try await applyPatternFamilies(
                to: fixture.setup,
                nextFamilies: [pfBMIFamily()],
                on: fixture.app.db
            )

            let after = try pfManifestCacheMaterial(fixture.setup)
            #expect(
                before != after, "Adding a family must change the manifest bytes so the runner cache key invalidates")

            #expect(
                result.writtenFiles.sorted() == [
                    "publictest_bmi_category_01.py",
                    "publictest_bmi_category_02.py",
                    "publictest_bmi_category_03.py",
                ])
            #expect(result.deletedFiles.isEmpty)

            // Zip actually contains the generated files.
            let entries = Set(listZipEntries(zipPath: fixture.setup.zipPath))
            for f in result.writtenFiles {
                #expect(entries.contains(f), "Zip missing generated file \(f)")
            }

            // Manifest carries the family spec + generatedBy tags on entries.
            let props = try pfDecodeManifest(fixture.setup.manifest)
            #expect(props.patternFamilies.count == 1)
            #expect(props.patternFamilies[0].id == "bmi_category")
            let generatedEntries = props.testSuites.filter { $0.generatedBy != nil }
            #expect(generatedEntries.count == 3)
            for entry in generatedEntries {
                #expect(entry.generatedBy == "bmi_category")
            }

        }
    }

    /// The /edit/save flow rebuilds the zip + manifest from the visible UI
    /// suite rows (which filter out generated scripts) and then re-applies
    /// pattern families.  This test simulates that sequence and verifies that
    /// families survive a zip+manifest rebuild: the family spec persists in
    /// the manifest, generated .py files land back in the zip, and the
    /// manifest's testSuites carry `generatedBy` tags.  Regression guard for
    /// the v0.4.76 bug where families silently vanished on Save.
    @Test func apply_surviveEditSaveManifestRebuild() async throws {
        try await withPatternFamilyFixture { fixture in

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
                to: fixture.setup, nextFamilies: [pfBMIFamily()], on: fixture.app.db
            )

            // Sanity: both raw + generated present before the rebuild.
            let beforeEntries = Set(listZipEntries(zipPath: fixture.setup.zipPath))
            #expect(beforeEntries.contains("publictest_handmade.py"))
            #expect(beforeEntries.contains("publictest_bmi_category_01.py"))

            // Simulate /edit/save: rewrite the zip from "visible" rows only
            // (raw scripts) — this intentionally drops the generated .py files
            // from the zip, matching what createRunnerSetupZip does.  Then
            // rebuild the manifest forwarding the existing pattern families,
            // and re-apply them to restore generated files.
            let existingFamilies = try pfDecodeManifest(fixture.setup.manifest).patternFamilies
            #expect(existingFamilies.count == 1, "family must survive into the existing manifest")

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
            #expect(
                afterEntries.contains("publictest_handmade.py"),
                "Raw script must survive")
            #expect(
                afterEntries.contains("publictest_bmi_category_01.py"),
                "Generated script must be restored by applyPatternFamilies")
            #expect(afterEntries.contains("publictest_bmi_category_02.py"))
            #expect(afterEntries.contains("publictest_bmi_category_03.py"))

            let props = try pfDecodeManifest(fixture.setup.manifest)
            #expect(props.patternFamilies.count == 1)
            #expect(props.patternFamilies[0].id == "bmi_category")
            let generatedEntries = props.testSuites.filter { $0.generatedBy != nil }
            #expect(generatedEntries.count == 3)
            // Each generated entry's display name must carry the case label so
            // the student result view shows distinct, labelled test rows.
            let names = Set(generatedEntries.compactMap(\.name))
            #expect(names.contains("BMI < 18.5 is underweight"))
            #expect(names.contains("BMI = 18.5 is normal"))
            #expect(names.contains("BMI >= 30 is obese"))

        }
    }

    @Test func apply_removingCaseDeletesItsScript() async throws {
        try await withPatternFamilyFixture { fixture in

            _ = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [pfBMIFamily()], on: fixture.app.db)

            // Re-apply with case "02" removed.
            let reduced = PatternFamily(
                id: "bmi_category", name: "BMI Category Boundaries",
                kind: .boundaryEquality, functionName: "bmi_category",
                paramNames: ["bmi"],
                defaults: PatternDefaults(hint: "hint"),
                cases: pfBMIFamily().cases.filter { $0.key != "02" }
            )

            let result = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [reduced], on: fixture.app.db)
            #expect(result.deletedFiles == ["publictest_bmi_category_02.py"])
            let entries = Set(listZipEntries(zipPath: fixture.setup.zipPath))
            #expect(entries.contains("publictest_bmi_category_02.py") == false)
            #expect(entries.contains("publictest_bmi_category_01.py"))

        }
    }

    @Test func apply_removingEntireFamilyCleansUpAllItsScripts() async throws {
        try await withPatternFamilyFixture { fixture in

            _ = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [pfBMIFamily()], on: fixture.app.db)

            let result = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [], on: fixture.app.db)
            #expect(result.deletedFiles.count == 3)

            let props = try pfDecodeManifest(fixture.setup.manifest)
            #expect(props.patternFamilies.isEmpty)
            #expect(props.testSuites.contains { $0.generatedBy != nil } == false)

        }
    }

    @Test func apply_preservesHandWrittenScripts() async throws {
        try await withPatternFamilyFixture { fixture in

            // Pre-seed a hand-written script before applying a family.
            try updateScriptInZip(
                zipPath: fixture.setup.zipPath,
                filename: "publictest_handmade.py",
                content: "# handmade\npassed('ok')\n"
            )
            fixture.setup.manifest = try #require(
                updateManifestAddingScript(
                    manifestJSON: fixture.setup.manifest,
                    entry: ConfiguredSuiteEntry(
                        script: "publictest_handmade.py", tier: "public", order: 1,
                        dependsOn: [], points: 1, displayName: nil, generatedBy: nil
                    )
                ))
            try await fixture.setup.save(on: fixture.app.db)

            _ = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [pfBMIFamily()], on: fixture.app.db)

            let entries = Set(listZipEntries(zipPath: fixture.setup.zipPath))
            #expect(
                entries.contains("publictest_handmade.py"),
                "Hand-written scripts must survive a family apply")

            let props = try pfDecodeManifest(fixture.setup.manifest)
            #expect(props.testSuites.contains { $0.script == "publictest_handmade.py" && $0.generatedBy == nil })

        }
    }

    @Test func apply_rejectsFilenameCollisionAndLeavesSetupUnchanged() async throws {
        try await withPatternFamilyFixture { fixture in

            // Create a hand-written file that will collide with a generated name.
            try updateScriptInZip(
                zipPath: fixture.setup.zipPath,
                filename: "publictest_bmi_category_01.py",
                content: "# handmade clash\npassed('ok')\n"
            )
            fixture.setup.manifest = try #require(
                updateManifestAddingScript(
                    manifestJSON: fixture.setup.manifest,
                    entry: ConfiguredSuiteEntry(
                        script: "publictest_bmi_category_01.py", tier: "public", order: 1,
                        dependsOn: [], points: 1, displayName: nil
                    )
                ))
            try await fixture.setup.save(on: fixture.app.db)
            let manifestBefore = fixture.setup.manifest
            let zipEntriesBefore = Set(listZipEntries(zipPath: fixture.setup.zipPath))

            do {
                _ = try await applyPatternFamilies(
                    to: fixture.setup, nextFamilies: [pfBMIFamily()], on: fixture.app.db)
                Issue.record("Expected validation to reject the family")
            } catch let abort as AbortError {
                #expect("\(abort.reason)".contains("hand-written script"))
            }
            #expect(fixture.setup.manifest == manifestBefore, "Failed validation must not mutate the manifest")
            #expect(
                Set(listZipEntries(zipPath: fixture.setup.zipPath)) == zipEntriesBefore,
                "Failed validation must not mutate the zip")

        }
    }

    // MARK: - family:<id> dependency expansion

    /// When a raw script declares `dependsOn: ["family:bmi_category"]`, the
    /// persisted manifest that reaches the runner must have that token
    /// expanded to the family's actual enabled generated filenames — the
    /// runner has no notion of families.
    @Test func apply_expandsFamilyRefOnRawScriptDep() async throws {
        try await withPatternFamilyFixture { fixture in

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
                nextFamilies: [pfBMIFamily()],
                authoredItems: [.script(rawEntry), .family(id: "bmi_category")],
                on: fixture.app.db
            )

            let props = try pfDecodeManifest(fixture.setup.manifest)
            let followup = try #require(props.testSuites.first { $0.script == "publictest_followup.py" })
            #expect(
                Set(followup.dependsOn)
                    == Set([
                        "publictest_bmi_category_01.py",
                        "publictest_bmi_category_02.py",
                        "publictest_bmi_category_03.py",
                    ]), "family:<id> must expand to all enabled generated filenames")
            // No `family:` tokens must survive into the persisted manifest.
            for entry in props.testSuites {
                for dep in entry.dependsOn {
                    #expect(
                        dep.hasPrefix("family:") == false, "Persisted dep '\(dep)' must be a filename, not a family ref"
                    )
                }
            }

        }
    }

    /// Family-level `dependsOn` propagates to every generated case, with
    /// family-ref tokens expanded to the referenced family's filenames.
    @Test func apply_familyLevelDepsExpandedAndInheritedByCases() async throws {
        try await withPatternFamilyFixture { fixture in

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
                cases: pfBMIFamily().cases,
                dependsOn: ["publictest_prereq.py"]
            )

            _ = try await applyPatternFamilies(
                to: fixture.setup,
                nextFamilies: [family],
                authoredItems: [.script(prereq), .family(id: family.id)],
                on: fixture.app.db
            )

            let props = try pfDecodeManifest(fixture.setup.manifest)
            let generated = props.testSuites.filter { $0.generatedBy != nil }
            #expect(generated.count == 3)
            for g in generated {
                #expect(
                    g.dependsOn == ["publictest_prereq.py"], "Every generated case must inherit the family-level dep")
            }

        }
    }

    /// Removing a family drops `family:<id>` tokens from other entries'
    /// dependsOn — no dangling refs remain.
    @Test func apply_removingFamilyClearsFamilyRefsFromOtherEntries() async throws {
        try await withPatternFamilyFixture { fixture in

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
                nextFamilies: [pfBMIFamily()],
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
            let props = try pfDecodeManifest(fixture.setup.manifest)
            let entry = try #require(props.testSuites.first { $0.script == "publictest_followup.py" })
            #expect(entry.dependsOn.isEmpty)
            #expect(props.patternFamilies.isEmpty)

        }
    }

    /// The authored-graph cycle detector rejects script→family→script cycles.
    @Test func apply_rejectsScriptFamilyScriptCycle() async throws {
        try await withPatternFamilyFixture { fixture in

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
                cases: pfBMIFamily().cases,
                dependsOn: ["publictest_a.py"]
            )

            do {
                _ = try await applyPatternFamilies(
                    to: fixture.setup,
                    nextFamilies: [family],
                    authoredItems: [.script(a), .family(id: family.id)],
                    on: fixture.app.db
                )
                Issue.record("Expected cycle to be rejected")
            } catch let abort as AbortError {
                #expect(
                    "\(abort.reason)".contains("cycle"),
                    "Expected cycle error, got: \(abort.reason)")
            }

        }
    }

    /// Family-to-family cycles are rejected too.
    @Test func apply_rejectsFamilyFamilyCycle() async throws {
        try await withPatternFamilyFixture { fixture in

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
                Issue.record("Expected cycle to be rejected")
            } catch let abort as AbortError {
                #expect("\(abort.reason)".contains("cycle"))
            }

        }
    }

    /// Self-referential families (`family: F depends on family:F`) are rejected.
    @Test func apply_rejectsSelfReferentialFamily() async throws {
        try await withPatternFamilyFixture { fixture in

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
                Issue.record("Expected self-ref to be rejected")
            } catch let abort as AbortError {
                #expect("\(abort.reason)".contains("itself") || "\(abort.reason)".contains("cycle"))
            }

        }
    }

    /// Referencing a family id that doesn't exist yields a readable error.
    @Test func apply_rejectsUnknownFamilyRef() async throws {
        try await withPatternFamilyFixture { fixture in

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
                Issue.record("Expected unknown-family-ref rejection")
            } catch let abort as AbortError {
                #expect("\(abort.reason)".contains("does_not_exist"))
            }

        }
    }

    // MARK: - Editable family points round-trip

    /// When `family.defaults.points` is non-default, every generated
    /// `TestSuiteEntry.points` in the manifest must carry it — this is
    /// how the suite editor's family-row Pts input propagates.
    @Test func apply_familyDefaultPointsPropagatesToGeneratedEntries() async throws {
        try await withPatternFamilyFixture { fixture in

            var family = pfBMIFamily()
            family = PatternFamily(
                id: family.id, name: family.name, kind: family.kind,
                functionName: family.functionName, paramNames: family.paramNames,
                defaults: PatternDefaults(tier: .pub, points: 5, hint: family.defaults.hint),
                cases: family.cases
            )
            _ = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [family], on: fixture.app.db)
            let props = try pfDecodeManifest(fixture.setup.manifest)
            let generated = props.testSuites.filter { $0.generatedBy != nil }
            #expect(generated.count == 3)
            for entry in generated {
                #expect(entry.points == 5, "family.defaults.points=5 must propagate to every generated entry")
            }

        }
    }

    // MARK: - Authored order preservation (ordering regression guard)

    /// Given authored `[script_a, family(3 cases), script_b]`, the final
    /// `testSuites` array must be `[script_a, family_01, family_02,
    /// family_03, script_b]` in that exact order.  `topologicallySorted`
    /// must not reorder entries that have no dependencies.  Pins the
    /// invariant that made the v0.4.79 "generated rows render at end"
    /// observation a legacy-manifest issue rather than a new-code bug.
    @Test func apply_authoredOrderPreservedInManifestAndOutcomes() async throws {
        try await withPatternFamilyFixture { fixture in

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
                nextFamilies: [pfBMIFamily()],
                authoredItems: [.script(a), .family(id: "bmi_category"), .script(b)],
                on: fixture.app.db
            )
            let props = try pfDecodeManifest(fixture.setup.manifest)
            #expect(
                props.testSuites.map(\.script) == [
                    "publictest_a.py",
                    "publictest_bmi_category_01.py",
                    "publictest_bmi_category_02.py",
                    "publictest_bmi_category_03.py",
                    "publictest_b.py",
                ])

        }
    }

    /// Regression guard for the v0.4.95 "family results render at the end
    /// instead of in-line" bug.  Before the fix, `topologicallySorted` was
    /// a FIFO Kahn that let trailing no-dep scripts "cut in line" ahead of
    /// a family that the author had positioned *right* after its prereq —
    /// because the family's generated entries re-enter the queue AFTER
    /// every no-dep node already in it.  With authored-position priority,
    /// the family stays next to its prerequisite, matching what the
    /// instructor saw in the suite editor.
    @Test func apply_familyWithDependencyStaysInlineAfterPrereq() async throws {
        try await withPatternFamilyFixture { fixture in

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
                cases: pfBMIFamily().cases,
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

            let props = try pfDecodeManifest(fixture.setup.manifest)
            #expect(
                props.testSuites.map(\.script) == [
                    "publictest_prereq.py",
                    "publictest_bmi_category_01.py",
                    "publictest_bmi_category_02.py",
                    "publictest_bmi_category_03.py",
                    "publictest_tail.py",
                ], "Family-with-dep must render in-line with its prerequisite, not pushed to the end of the suite.")

        }
    }

    /// The `PUT /families` path invokes `applyPatternFamilies` with
    /// `authoredItems == nil` (the legacy branch).  When the family
    /// already has generated entries in the existing manifest, the legacy
    /// branch must keep the family anchored at its first-generated-entry
    /// position and must NOT dump it at the end of the suite.  Regression
    /// guard for v0.4.81's position-preservation fix and for the "family
    /// gets pushed to bottom when I edit its cases" user-reported bug.
    @Test func apply_editingExistingFamilyPreservesMiddlePosition() async throws {
        try await withPatternFamilyFixture { fixture in

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
                nextFamilies: [pfBMIFamily()],
                authoredItems: [.script(a), .family(id: "bmi_category"), .script(b)],
                on: fixture.app.db
            )

            // Now simulate `PUT /families` editing the family: mutate case 02
            // to have a different expected value and re-apply *without*
            // authoredItems (that's how the family-editor modal save wires up).
            var edited = pfBMIFamily().cases
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

            let props = try pfDecodeManifest(fixture.setup.manifest)
            #expect(
                props.testSuites.map(\.script) == [
                    "publictest_a.py",
                    "publictest_bmi_category_01.py",
                    "publictest_bmi_category_02.py",
                    "publictest_bmi_category_03.py",
                    "publictest_b.py",
                ],
                "Editing a family's cases via the PUT /families legacy path must keep the family at its original middle position — not push it to the end of the suite."
            )

        }
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
    @Test func apply_createPublishPreservesFamilyPosition() async throws {
        try await withPatternFamilyFixture { fixture in

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
                nextFamilies: [pfBMIFamily()],
                authoredItems: [.script(a), .family(id: "bmi_category"), .script(b)],
                on: fixture.app.db
            )
            let draftProps = try pfDecodeManifest(fixture.setup.manifest)

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

            let props = try pfDecodeManifest(fixture.setup.manifest)
            #expect(
                props.testSuites.map(\.script) == [
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

}
