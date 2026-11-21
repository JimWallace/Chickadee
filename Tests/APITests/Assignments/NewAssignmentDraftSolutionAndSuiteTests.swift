// Tests/APITests/Assignments/NewAssignmentDraftSolutionAndSuiteTests.swift
//
// The solution-notebook and suite-file actions of `NewAssignmentDraftService`,
// which `NewAssignmentDraftServiceTests` does not reach: create a blank
// solution, copy the assignment notebook into the solution, upload a valid
// solution, clear the solution, and replace the suite files. Each test builds
// the service directly and dispatches through `perform()`, so the action names
// are pinned too.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class NewAssignmentDraftSolutionAndSuiteTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-draft-sol")
    }

    // MARK: - Fixtures

    private func notebookData(markdown: String = "Intro", code: String = "# marker") -> Data {
        let json = """
            {
              "cells": [
                {"cell_type": "markdown", "source": ["\(markdown)\\n"], "metadata": {}},
                {"cell_type": "code", "source": ["\(code)\\n"], "metadata": {}, "outputs": [], "execution_count": null}
              ],
              "metadata": {"kernelspec": {"name": "python3", "display_name": "Python 3"}, "language_info": {"name": "python"}},
              "nbformat": 4,
              "nbformat_minor": 5
            }
            """
        return Data(json.utf8)
    }

    private func makeFile(named name: String, contents: Data) -> File {
        var buffer = ByteBufferAllocator().buffer(capacity: contents.count)
        buffer.writeBytes(contents)
        return File(data: buffer, filename: name)
    }

    private func makePayload(
        action: String,
        solutionNotebookFile: File? = nil,
        suiteFiles: [File] = [],
        assignmentType: String = ""
    ) -> NewAssignmentDraftPayload {
        var payload = NewAssignmentDraftPayload(
            assignmentName: "Vital Signs",
            dueAt: "",
            startsAt: "",
            sectionIDRaw: "",
            draftIDRaw: nil,
            action: action,
            assignmentNotebookFile: nil,
            solutionNotebookFile: solutionNotebookFile,
            suiteFiles: suiteFiles,
            suiteConfigRaw: nil,
            requiredPlatform: "",
            requiredArchitecture: "",
            requiredLanguagesCSV: "",
            requiredCapabilitiesCSV: "",
            assignmentLanguage: "python"
        )
        payload.assignmentType = assignmentType
        return payload
    }

    private func insertDraftSetup(id: String) async throws -> (UUID, APITestSetup) {
        let courseID = try await app.testCourseID(code: "DSOL101", name: "Draft Solution Course")
        let manifest = """
            {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
            """
        try FileManager.default.createDirectory(
            atPath: app.testSetupsDirectory, withIntermediateDirectories: true)
        let zipPath = app.testSetupsDirectory + "\(id).zip"
        try Data().write(to: URL(fileURLWithPath: zipPath))
        let setup = APITestSetup(id: id, manifest: manifest, zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        return (courseID, setup)
    }

    private func makeService(
        courseID: UUID, setup: APITestSetup, payload: NewAssignmentDraftPayload
    ) -> NewAssignmentDraftService {
        NewAssignmentDraftService(
            application: app, db: app.db, logger: app.logger,
            setup: setup,
            setupID: setup.id ?? "",
            userID: UUID(),
            courseID: courseID,
            formState: NewAssignmentDraftFormState.empty,
            payload: payload
        )
    }

    private func solutionPath(_ setup: APITestSetup) -> String {
        draftSolutionNotebookPath(testSetupsDirectory: app.testSetupsDirectory, setupID: setup.id ?? "")
    }

    private func solutionText(_ setup: APITestSetup) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: solutionPath(setup)))
        return try #require(String(bytes: data, encoding: .utf8))
    }

    // MARK: - create-solution-notebook

    /// A blank solution carries the assignment title with " Solution" and the
    /// declared language's kernel.
    @Test func createSolutionNotebookWritesABlankSolutionInTheDeclaredLanguage() async throws {
        try await withApp(app) { app in
            let (courseID, setup) = try await insertDraftSetup(id: "sol_create_r")
            try await declareManifestLanguage(setup: setup, to: .r, on: app.db)
            var service = makeService(
                courseID: courseID, setup: setup, payload: makePayload(action: "create-solution-notebook"))

            #expect(try await service.perform() == .applied)

            #expect(service.formState.solutionNotebookName == "solution.ipynb")
            let text = try solutionText(setup)
            #expect(text.contains("Vital Signs Solution"))
            #expect(text.contains("\"language\": \"r\""))
            // The solution never becomes the starter notebook.
            #expect(setup.notebookPath == nil)
        }
    }

    /// An upload-only language has no notebook editor, so the action is
    /// refused and nothing is written.
    @Test func createSolutionNotebookIsRefusedForAnUploadOnlyLanguage() async throws {
        try await withApp(app) { app in
            let (courseID, setup) = try await insertDraftSetup(id: "sol_create_cpp")
            try await declareManifestLanguage(setup: setup, to: .cpp, on: app.db)
            var service = makeService(
                courseID: courseID, setup: setup, payload: makePayload(action: "create-solution-notebook"))

            await #expect(throws: AppError.self) { try await service.perform() }

            #expect(service.formState.solutionNotebookName == nil)
            #expect(!FileManager.default.fileExists(atPath: solutionPath(setup)))
        }
    }

    // MARK: - create-solution-from-assignment

    /// The solution starts from the bytes of the assignment notebook.
    @Test func createSolutionFromAssignmentCopiesTheAssignmentNotebook() async throws {
        try await withApp(app) { _ in
            let (courseID, setup) = try await insertDraftSetup(id: "sol_from_copy")
            let dir = try ensureDraftNotebookDirectory(
                testSetupsDirectory: app.testSetupsDirectory, setupID: setup.id ?? "")
            let assignmentPath = dir + "assignment.ipynb"
            try notebookData(code: "# starter-marker-7781").write(to: URL(fileURLWithPath: assignmentPath))
            setup.notebookPath = assignmentPath
            try await setup.save(on: app.db)

            var service = makeService(
                courseID: courseID, setup: setup,
                payload: makePayload(action: "create-solution-from-assignment"))
            #expect(try await service.perform() == .applied)

            #expect(service.formState.solutionNotebookName == "solution.ipynb")
            let text = try solutionText(setup)
            #expect(text.contains("starter-marker-7781"))
            #expect(!text.contains("Vital Signs Solution"))
        }
    }

    /// With no assignment notebook yet, the solution is a blank one.
    @Test func createSolutionFromAssignmentFallsBackToABlankSolution() async throws {
        try await withApp(app) { _ in
            let (courseID, setup) = try await insertDraftSetup(id: "sol_from_blank")
            var service = makeService(
                courseID: courseID, setup: setup,
                payload: makePayload(action: "create-solution-from-assignment"))

            #expect(try await service.perform() == .applied)

            #expect(try solutionText(setup).contains("Vital Signs Solution"))
        }
    }

    /// An EMPTY assignment notebook file counts as no notebook: the solution
    /// is a blank one, not an empty file.
    @Test func createSolutionFromAssignmentTreatsAnEmptyFileAsMissing() async throws {
        try await withApp(app) { _ in
            let (courseID, setup) = try await insertDraftSetup(id: "sol_from_empty")
            let dir = try ensureDraftNotebookDirectory(
                testSetupsDirectory: app.testSetupsDirectory, setupID: setup.id ?? "")
            let assignmentPath = dir + "assignment.ipynb"
            try Data().write(to: URL(fileURLWithPath: assignmentPath))
            setup.notebookPath = assignmentPath
            try await setup.save(on: app.db)

            var service = makeService(
                courseID: courseID, setup: setup,
                payload: makePayload(action: "create-solution-from-assignment"))
            #expect(try await service.perform() == .applied)

            #expect(try solutionText(setup).contains("Vital Signs Solution"))
        }
    }

    /// An upload-only language with no notebook to copy has nothing to fall
    /// back to, so the action is refused.
    @Test func createSolutionFromAssignmentIsRefusedForAnUploadOnlyLanguageWithoutANotebook() async throws {
        try await withApp(app) { app in
            let (courseID, setup) = try await insertDraftSetup(id: "sol_from_cpp")
            try await declareManifestLanguage(setup: setup, to: .cpp, on: app.db)
            var service = makeService(
                courseID: courseID, setup: setup,
                payload: makePayload(action: "create-solution-from-assignment"))

            await #expect(throws: AppError.self) { try await service.perform() }

            #expect(!FileManager.default.fileExists(atPath: solutionPath(setup)))
        }
    }

    // MARK: - upload-solution-notebook

    /// A valid upload is stored at the draft solution path, the form shows the
    /// uploaded name, and the `## ` headers become suite sections.
    @Test func uploadSolutionNotebookStoresItAndScaffoldsSections() async throws {
        try await withApp(app) { _ in
            let (courseID, setup) = try await insertDraftSetup(id: "sol_upload_ok")
            let file = makeFile(
                named: "answers.ipynb",
                contents: notebookData(markdown: "## Blood Pressure", code: "# upload-marker-4410"))
            var service = makeService(
                courseID: courseID, setup: setup,
                payload: makePayload(action: "upload-solution-notebook", solutionNotebookFile: file))

            #expect(try await service.perform() == .applied)

            #expect(service.formState.solutionNotebookName == "answers.ipynb")
            #expect(try solutionText(setup).contains("upload-marker-4410"))
            let props = try #require(setup.decodedManifest())
            #expect(props.sections.map(\.name) == ["Blood Pressure"])
        }
    }

    // MARK: - clear-solution-notebook

    @Test func clearSolutionNotebookRemovesTheFileAndTheName() async throws {
        try await withApp(app) { _ in
            let (courseID, setup) = try await insertDraftSetup(id: "sol_clear")
            var create = makeService(
                courseID: courseID, setup: setup, payload: makePayload(action: "create-solution-notebook"))
            _ = try await create.perform()
            #expect(FileManager.default.fileExists(atPath: solutionPath(setup)))

            var clear = makeService(
                courseID: courseID, setup: setup, payload: makePayload(action: "clear-solution-notebook"))
            clear.formState.solutionNotebookName = "solution.ipynb"
            #expect(try await clear.perform() == .applied)

            #expect(clear.formState.solutionNotebookName == nil)
            #expect(!FileManager.default.fileExists(atPath: solutionPath(setup)))
        }
    }

    // MARK: - replace-suite-files

    /// A shell test script becomes a suite entry; a support file does not.
    /// The declared language survives, and the starter notebook name comes
    /// from the stored notebook path.
    @Test func replaceSuiteFilesBuildsTheSuiteFromTheUpload() async throws {
        try await withApp(app) { app in
            let (courseID, setup) = try await insertDraftSetup(id: "sol_suite_replace")
            try await declareManifestLanguage(setup: setup, to: .r, on: app.db)
            setup.notebookPath = app.testSetupsDirectory + "notebooks/sol_suite_replace/lab-one.ipynb"
            try await setup.save(on: app.db)
            let script = makeFile(
                named: "publictest_vitals.sh", contents: Data("#!/bin/sh\nexit 0\n".utf8))
            let support = makeFile(named: "readings.csv", contents: Data("hr,bp\n72,120\n".utf8))
            var service = makeService(
                courseID: courseID, setup: setup,
                payload: makePayload(action: "replace-suite-files", suiteFiles: [script, support]))

            #expect(try await service.perform() == .applied)

            let props = try #require(setup.decodedManifest())
            #expect(props.testSuites.map(\.script) == ["publictest_vitals.sh"])
            #expect(props.language == .r)
            #expect(props.starterNotebook == "lab-one.ipynb")
            // No type was chosen, so the draft is an Assignment: worker graded.
            #expect(props.gradingMode == .worker)
        }
    }

    /// The chosen type decides the grading mode: a Lab is browser graded.
    @Test func replaceSuiteFilesUsesTheChosenTypesGradingMode() async throws {
        try await withApp(app) { _ in
            let (courseID, setup) = try await insertDraftSetup(id: "sol_suite_lab")
            let script = makeFile(
                named: "publictest_lab.sh", contents: Data("#!/bin/sh\nexit 0\n".utf8))
            var service = makeService(
                courseID: courseID, setup: setup,
                payload: makePayload(action: "replace-suite-files", suiteFiles: [script], assignmentType: "lab"))

            #expect(try await service.perform() == .applied)

            let props = try #require(setup.decodedManifest())
            #expect(props.gradingMode == .browser)
            #expect(props.starterNotebook == "assignment.ipynb")
        }
    }

    /// An unknown type is refused before the manifest changes.
    @Test func replaceSuiteFilesRefusesAnUnknownType() async throws {
        try await withApp(app) { _ in
            let (courseID, setup) = try await insertDraftSetup(id: "sol_suite_bad_type")
            let before = setup.manifest
            let script = makeFile(
                named: "publictest_x.sh", contents: Data("#!/bin/sh\nexit 0\n".utf8))
            var service = makeService(
                courseID: courseID, setup: setup,
                payload: makePayload(
                    action: "replace-suite-files", suiteFiles: [script], assignmentType: "seminar"))

            await #expect(throws: AppError.self) { try await service.perform() }

            #expect(setup.manifest == before)
        }
    }
}
