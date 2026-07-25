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
    /// manifest says `.python`; the `xr` kernel is the only thing that knows
    /// better, and it has to reach the save path or the assignment is recorded
    /// as Python forever.
    @Test func firstSaveOfAnRNotebookAssignmentRecordsR() async throws {
        try await withPatternFamilyFixture { fixture in
            let manifest = try pfDecodeManifest(fixture.setup.manifest)
            #expect(AssignmentLanguage.resolve(manifest: manifest) == .python)

            try await attachNotebook(fixture, kernel: "xr")
            #expect(AssignmentLanguage.resolve(for: fixture.setup, manifest: manifest) == .r)

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

            let result = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [pfBMIFamily()], on: fixture.app.db)

            #expect(result.writtenFiles.allSatisfy { $0.hasSuffix(".py") })
            let saved = try pfDecodeManifest(fixture.setup.manifest)
            #expect(saved.language == .python)
        }
    }

    /// A setup with no notebook resolves exactly as it did before, so nothing
    /// regresses for script-only assignments.
    @Test func setupWithoutANotebookResolvesFromTheManifestAlone() async throws {
        try await withPatternFamilyFixture { fixture in
            #expect(fixture.setup.notebookPath == nil)
            let manifest = try pfDecodeManifest(fixture.setup.manifest)
            #expect(AssignmentLanguage.resolve(for: fixture.setup, manifest: manifest) == .python)

            let rSuite = TestProperties(testSuites: [TestSuiteEntry(tier: .pub, script: "publictest_a.R")])
            #expect(AssignmentLanguage.resolve(for: fixture.setup, manifest: rSuite) == .r)
        }
    }

    /// A `notebookPath` pointing at a file that is gone (or isn't a notebook)
    /// must not throw or flip the answer — it falls back to the manifest.
    @Test func missingOrUnparseableNotebookFallsBackToTheManifest() async throws {
        try await withPatternFamilyFixture { fixture in
            let manifest = try pfDecodeManifest(fixture.setup.manifest)

            fixture.setup.notebookPath = fixture.app.testSetupsDirectory + "does-not-exist.ipynb"
            #expect(AssignmentLanguage.resolve(for: fixture.setup, manifest: manifest) == .python)

            let junk = fixture.app.testSetupsDirectory + "junk.ipynb"
            try Data("not a notebook".utf8).write(to: URL(fileURLWithPath: junk))
            fixture.setup.notebookPath = junk
            #expect(AssignmentLanguage.resolve(for: fixture.setup, manifest: manifest) == .python)
        }
    }
}
