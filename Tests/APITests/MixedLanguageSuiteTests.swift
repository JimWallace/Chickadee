// Tests/APITests/MixedLanguageSuiteTests.swift
//
// A suite may hold scripts in languages other than the one the assignment
// declares, and doing so must not change the assignment.
//
// This is not an edge case bolted on — it is how grading has always worked.
// `scriptInvocation(for:)` takes only a URL and classifies each script
// independently, and the runner stages EVERY language's `test_runtime.*` into
// every job workspace. So a hand-written `.R` helper inside a Python assignment
// runs under `Rscript`, and always did.
//
// What did not hold up was the authoring side. `resolveAuthoringLanguage` used
// to scan the authored scripts and let a non-Python extension outrank the stored
// declaration, so saving one `helper_test.R` into a Python assignment re-rendered
// every generated script in R, deleted the `.py` ones, and wrote `.r` into the
// manifest — a language migration nobody asked for, triggered by adding a
// helper. These pin the corrected rule: the declaration governs what Chickadee
// GENERATES; the suite's contents govern only what gets executed, and they do
// not vote on the declaration.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct MixedLanguageSuiteTests {

    /// Authoring an off-language raw script leaves the declaration, the
    /// generated scripts, and their extensions exactly as they were.
    @Test func anOffLanguageHelperDoesNotMigrateTheAssignment() async throws {
        try await withPatternFamilyFixture(declaredLanguage: .python) { fixture in
            // A Python assignment with a generated family: the thing that would
            // be re-rendered and deleted if content still voted.
            let first = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [pfBMIFamily()], on: fixture.app.db)
            #expect(first.writtenFiles.allSatisfy { $0.hasSuffix(".py") })
            let generatedBefore = Set(
                try pfDecodeManifest(fixture.setup.manifest)
                    .testSuites.filter { $0.generatedBy != nil }.map(\.script))
            #expect(!generatedBefore.isEmpty)

            // Now the author adds a hand-written R helper beside it.
            try updateScriptInZip(
                zipPath: fixture.setup.zipPath,
                filename: "helper_test.R",
                content: "cat(\"ok\\n\")\n"
            )
            let props = try pfDecodeManifest(fixture.setup.manifest)
            var authored: [AuthoredSuiteItem] = props.testSuites
                .filter { $0.generatedBy == nil && $0.generatedByCheck == nil }
                .map {
                    .script(
                        AuthoredRawScript(
                            script: $0.script, tier: $0.tier, points: $0.points,
                            displayName: nil, dependsOn: [], sectionID: nil))
                }
            authored.append(
                .script(
                    AuthoredRawScript(
                        script: "helper_test.R", tier: .pub, points: 1,
                        displayName: nil, dependsOn: [], sectionID: nil)))
            authored.append(.family(id: "bmi_category", sectionID: nil))

            let result = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [pfBMIFamily()], authoredItems: authored,
                on: fixture.app.db)

            let after = try pfDecodeManifest(fixture.setup.manifest)
            #expect(
                after.language == .python,
                "a hand-written .R helper must not re-declare a Python assignment as R")
            #expect(after.languageDeclared == true)

            // The generated scripts are untouched — same names, still `.py`.
            let generatedAfter = Set(
                after.testSuites.filter { $0.generatedBy != nil }.map(\.script))
            #expect(generatedAfter == generatedBefore)
            #expect(
                result.deletedFiles.isEmpty,
                "nothing may be deleted: a migration would have removed the .py scripts")

            // And the helper is in the suite, in its own language.
            #expect(after.testSuites.contains { $0.script == "helper_test.R" })
        }
    }

    /// The same in the other direction, which used to be the asymmetry: a `.py`
    /// helper could never flip an R assignment, because Python was excluded by
    /// name. Both directions are inert now, for the same reason.
    @Test func aPythonHelperDoesNotMigrateAnRAssignment() async throws {
        try await withPatternFamilyFixture(declaredLanguage: .r) { fixture in
            try updateScriptInZip(
                zipPath: fixture.setup.zipPath, filename: "helper_test.py",
                content: "print('ok')\n")
            let authored: [AuthoredSuiteItem] = [
                .script(
                    AuthoredRawScript(
                        script: "helper_test.py", tier: .pub, points: 1,
                        displayName: nil, dependsOn: [], sectionID: nil))
            ]
            _ = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [], authoredItems: authored, on: fixture.app.db)

            #expect(try pfDecodeManifest(fixture.setup.manifest).language == .r)
        }
    }

    /// Generated scripts still render in the DECLARED language when an
    /// off-language helper is present — the property that would break if the
    /// scan were restored, and the reason this is not simply "the sniff was
    /// redundant".
    @Test func generatedScriptsFollowTheDeclarationNotTheSuite() async throws {
        try await withPatternFamilyFixture(declaredLanguage: .python) { fixture in
            try updateScriptInZip(
                zipPath: fixture.setup.zipPath, filename: "helper_test.lua",
                content: "print('ok')\n")
            let authored: [AuthoredSuiteItem] = [
                .script(
                    AuthoredRawScript(
                        script: "helper_test.lua", tier: .pub, points: 1,
                        displayName: nil, dependsOn: [], sectionID: nil)),
                .family(id: "bmi_category", sectionID: nil),
            ]
            let result = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [pfBMIFamily()], authoredItems: authored,
                on: fixture.app.db)

            #expect(result.writtenFiles.allSatisfy { $0.hasSuffix(".py") })
            #expect(try pfDecodeManifest(fixture.setup.manifest).language == .python)
        }
    }
}
