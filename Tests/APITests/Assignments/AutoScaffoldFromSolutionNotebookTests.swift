// Tests/APITests/Assignments/AutoScaffoldFromSolutionNotebookTests.swift
//
// `autoScaffoldFromSolutionNotebook`: on a fresh test setup, a solution
// notebook's `## ` headers become suite sections. It is one-shot. A setup that
// already has sections or test entries is left alone, so a re-upload cannot
// overwrite what an instructor arranged. No per-function scripts are written.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct AutoScaffoldFromSolutionNotebookTests {

    /// A notebook whose markdown cells hold `headings`, each followed by one
    /// code cell that defines a Python function.
    private func notebook(headings: [String], code: String = "def area(r):\n    return r * r\n") throws -> Data {
        var cells: [[String: Any]] = []
        for heading in headings {
            cells.append(["cell_type": "markdown", "metadata": [:], "source": heading])
            cells.append([
                "cell_type": "code", "execution_count": NSNull(), "metadata": [:], "outputs": [],
                "source": code,
            ])
        }
        if headings.isEmpty {
            cells.append([
                "cell_type": "code", "execution_count": NSNull(), "metadata": [:], "outputs": [],
                "source": code,
            ])
        }
        let notebook: [String: Any] = ["cells": cells, "metadata": [:], "nbformat": 4, "nbformat_minor": 5]
        return try JSONSerialization.data(withJSONObject: notebook)
    }

    private func setup(
        id: String, _ props: TestProperties, on app: Application
    ) async throws -> APITestSetup {
        try await arInsertSetup(id: id, manifest: try encodeManifest(props), on: app)
    }

    private func reloaded(_ id: String, on app: Application) async throws -> TestProperties {
        let row = try #require(try await APITestSetup.find(id, on: app.db))
        return try #require(row.decodedManifest())
    }

    // MARK: - A fresh setup is scaffolded

    @Test func aFreshSetupGetsOneSectionPerHeaderInNotebookOrder() async throws {
        try await withTestApp { app in
            let props = TestProperties(timeLimitSeconds: 42, language: .python)
            let row = try await setup(id: "scaffold_fresh", props, on: app)

            let result = try await autoScaffoldFromSolutionNotebook(
                setup: row, notebookData: try notebook(headings: ["## Part A", "## Part B"]), on: app.db)

            #expect(result.sections == 2)
            #expect(result.functions == 0, "the scaffold writes no per-function scripts")
            let saved = try await reloaded("scaffold_fresh", on: app)
            #expect(saved.sections.map(\.name) == ["Part A", "Part B"])
            #expect(Set(saved.sections.map(\.id)).count == 2, "each section gets its own id")
            #expect(saved.sections.allSatisfy { UUID(uuidString: $0.id) != nil })
            #expect(saved.testSuites.isEmpty)
            #expect(saved.timeLimitSeconds == 42, "every other field is kept")
            #expect(saved.language == .python)
        }
    }

    /// A section is a markdown header, so it does not depend on whether the
    /// scanner can read the language's functions.
    @Test func sectionsAreScaffoldedForALanguageOtherThanPython() async throws {
        try await withTestApp { app in
            let row = try await setup(id: "scaffold_r", TestProperties(language: .r), on: app)

            let result = try await autoScaffoldFromSolutionNotebook(
                setup: row,
                notebookData: try notebook(headings: ["## Summaries"], code: "area <- function(r) r * r\n"),
                on: app.db)

            #expect(result.sections == 1)
            let saved = try await reloaded("scaffold_r", on: app)
            #expect(saved.sections.map(\.name) == ["Summaries"])
        }
    }

    /// Headers alone are enough. A solution that organizes its work under
    /// headers and defines no top-level function still gets its sections.
    @Test func headersWithoutFunctionsAreScaffolded() async throws {
        try await withTestApp { app in
            let row = try await setup(id: "scaffold_nofns", TestProperties(language: .python), on: app)

            let result = try await autoScaffoldFromSolutionNotebook(
                setup: row, notebookData: try notebook(headings: ["## Load", "## Clean"], code: "x = 1\n"),
                on: app.db)

            #expect(result.sections == 2)
            let saved = try await reloaded("scaffold_nofns", on: app)
            #expect(saved.sections.map(\.name) == ["Load", "Clean"])
        }
    }

    // MARK: - A setup with structure is left alone

    @Test func aSetupWithSectionsIsLeftAlone() async throws {
        try await withTestApp { app in
            let props = TestProperties(
                language: .python, sections: [TestSuiteSection(id: "kept", name: "Arranged by hand")])
            let row = try await setup(id: "scaffold_hassections", props, on: app)
            let before = row.manifest

            let result = try await autoScaffoldFromSolutionNotebook(
                setup: row, notebookData: try notebook(headings: ["## Part A"]), on: app.db)

            #expect(result.sections == 0)
            #expect(result.functions == 0)
            let after = try #require(try await APITestSetup.find("scaffold_hassections", on: app.db))
            #expect(after.manifest == before)
        }
    }

    @Test func aSetupWithTestEntriesIsLeftAlone() async throws {
        try await withTestApp { app in
            let props = TestProperties(
                testSuites: [TestSuiteEntry(tier: .pub, script: "test_area.py")], language: .python)
            let row = try await setup(id: "scaffold_hastests", props, on: app)
            let before = row.manifest

            let result = try await autoScaffoldFromSolutionNotebook(
                setup: row, notebookData: try notebook(headings: ["## Part A"]), on: app.db)

            #expect(result.sections == 0)
            let after = try #require(try await APITestSetup.find("scaffold_hastests", on: app.db))
            #expect(after.manifest == before)
            #expect(after.decodedManifest()?.testSuites.map(\.script) == ["test_area.py"])
        }
    }

    @Test func aManifestThatDoesNotDecodeIsLeftAlone() async throws {
        try await withTestApp { app in
            let row = try await arInsertSetup(id: "scaffold_badmanifest", manifest: "not a manifest", on: app)

            let result = try await autoScaffoldFromSolutionNotebook(
                setup: row, notebookData: try notebook(headings: ["## Part A"]), on: app.db)

            #expect(result.sections == 0)
            let after = try #require(try await APITestSetup.find("scaffold_badmanifest", on: app.db))
            #expect(after.manifest == "not a manifest")
        }
    }

    // MARK: - A notebook with nothing to scaffold

    @Test func aNotebookWithNoHeadersAndNoFunctionsWritesNothing() async throws {
        try await withTestApp { app in
            let row = try await setup(id: "scaffold_empty", TestProperties(language: .python), on: app)
            let before = row.manifest

            let result = try await autoScaffoldFromSolutionNotebook(
                setup: row, notebookData: try notebook(headings: [], code: "x = 1\n"), on: app.db)

            #expect(result.sections == 0)
            let after = try #require(try await APITestSetup.find("scaffold_empty", on: app.db))
            #expect(after.manifest == before)
        }
    }

    /// Functions without headers pass the "anything found" gate, but there is
    /// no section to declare and no script is written.
    @Test func functionsWithoutHeadersDeclareNoSectionsAndNoScripts() async throws {
        try await withTestApp { app in
            let row = try await setup(id: "scaffold_fnonly", TestProperties(language: .python), on: app)

            let result = try await autoScaffoldFromSolutionNotebook(
                setup: row, notebookData: try notebook(headings: []), on: app.db)

            #expect(result.sections == 0)
            #expect(result.functions == 0)
            let saved = try await reloaded("scaffold_fnonly", on: app)
            #expect(saved.sections.isEmpty)
            #expect(saved.testSuites.isEmpty)
        }
    }
}
