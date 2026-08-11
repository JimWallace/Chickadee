// Tests/APITests/AssignmentLanguageResolutionTests.swift
//
// The server-side resolution seam: `AssignmentLanguage.resolve(for:manifest:)`.
//
// A brand-new R notebook assignment is the case that used to fall through.  Its
// suite is empty and nothing has recorded a language, so the manifest alone
// answers `.python` — and the first save then *writes that answer down*, so the
// mistake is sticky.  These tests pin the starter notebook's kernelspec as the
// signal that carries that first save.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct AssignmentLanguageResolutionTests {

    /// Minimal `.ipynb` bytes — only the kernelspec matters here.
    private func notebookBytes(kernel: String) -> Data {
        let json = """
            {"cells": [], "nbformat": 4, "nbformat_minor": 5,
             "metadata": {"kernelspec": {"name": "\(kernel)", "language": "R"}}}
            """
        return Data(json.utf8)
    }

    /// Attaches a starter notebook to the fixture's setup, the way an upload does.
    private func attachNotebook(_ fixture: PFFixture, kernel: String) async throws {
        let path = fixture.app.testSetupsDirectory + "starter-\(UUID().uuidString).ipynb"
        try notebookBytes(kernel: kernel).write(to: URL(fileURLWithPath: path))
        fixture.setup.notebookPath = path
        try await fixture.setup.save(on: fixture.app.db)
    }

    /// The gap this closes.  With an empty suite and no recorded language the
    /// manifest names no language at all; the `xr` kernel is the only thing that
    /// knows better, and it has to reach the save path or the assignment is
    /// recorded wrong forever.
    @Test func firstSaveOfAnRNotebookAssignmentRecordsR() async throws {
        try await withPatternFamilyFixture(declaredLanguage: nil) { fixture in
            let manifest = try pfDecodeManifest(fixture.setup.manifest)
            // nil, not `.python`: an empty suite says nothing about the
            // language, and saying nothing used to be spelled "Python".
            #expect(AssignmentLanguage.derivedDeclaration(manifest: manifest, notebookData: nil) == nil)

            // ATTACHING AN R NOTEBOOK NO LONGER MAKES THE ASSIGNMENT R.
            // That was the old rule and it is the one this arc removed: a
            // kernelspec is content, and content does not declare a language.
            try await attachNotebook(fixture, kernel: "xr")
            #expect(
                AssignmentLanguage.resolve(for: fixture.setup, manifest: manifest) == nil,
                "a notebook kernel must not silently declare the language")

            // The author declares it — which is what every creation path now
            // does, and what the REST upload does on the author's behalf.
            try await declareManifestLanguage(setup: fixture.setup, to: .r, on: fixture.app.db)
            let declared = try pfDecodeManifest(fixture.setup.manifest)
            #expect(AssignmentLanguage.resolve(for: fixture.setup, manifest: declared) == .r)

            let result = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [pfBMIFamily()], on: fixture.app.db)

            #expect(result.writtenFiles.allSatisfy { $0.hasSuffix(".R") })
            let saved = try pfDecodeManifest(fixture.setup.manifest)
            #expect(saved.language == .r)
        }
    }

    /// The Python default is unchanged, and it is *recorded* rather than left
    /// to be re-inferred — so a later stray `.R` file can't flip the language.
    @Test func firstSaveOfAPythonNotebookAssignmentRecordsPython() async throws {
        try await withPatternFamilyFixture { fixture in
            try await attachNotebook(fixture, kernel: "python3")
            try await declareManifestLanguage(setup: fixture.setup, to: .python, on: fixture.app.db)

            let result = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [pfBMIFamily()], on: fixture.app.db)

            #expect(result.writtenFiles.allSatisfy { $0.hasSuffix(".py") })
            let saved = try pfDecodeManifest(fixture.setup.manifest)
            #expect(saved.language == .python)
        }
    }

    /// Resolution reads the declaration and nothing else — not the suite, not
    /// the notebook.
    ///
    /// The `.R` suite below used to resolve to `.r` through the extension
    /// sniff. It resolves to nil now, and that is the change: a graded script
    /// is content too. `derivedDeclaration` still reads it, because that is
    /// what the creation boundaries call to answer the question once.
    @Test func resolutionReadsTheDeclarationAndNothingElse() async throws {
        try await withPatternFamilyFixture(declaredLanguage: nil) { fixture in
            #expect(fixture.setup.notebookPath == nil)
            let manifest = try pfDecodeManifest(fixture.setup.manifest)
            #expect(AssignmentLanguage.resolve(for: fixture.setup, manifest: manifest) == nil)

            let rSuite = TestProperties(testSuites: [TestSuiteEntry(tier: .pub, script: "publictest_a.R")])
            #expect(AssignmentLanguage.resolve(for: fixture.setup, manifest: rSuite) == nil)
            #expect(AssignmentLanguage.derivedDeclaration(manifest: rSuite, notebookData: nil) == .r)
        }
    }

    /// A `notebookPath` pointing at a file that is gone (or isn't a notebook)
    /// must not throw or flip the answer — it falls back to the manifest.
    @Test func missingOrUnparseableNotebookFallsBackToTheManifest() async throws {
        try await withPatternFamilyFixture(declaredLanguage: nil) { fixture in
            let manifest = try pfDecodeManifest(fixture.setup.manifest)

            fixture.setup.notebookPath = fixture.app.testSetupsDirectory + "does-not-exist.ipynb"
            #expect(AssignmentLanguage.resolve(for: fixture.setup, manifest: manifest) == nil)

            let junk = fixture.app.testSetupsDirectory + "junk.ipynb"
            try Data("not a notebook".utf8).write(to: URL(fileURLWithPath: junk))
            fixture.setup.notebookPath = junk
            #expect(AssignmentLanguage.resolve(for: fixture.setup, manifest: manifest) == nil)
        }
    }
}
