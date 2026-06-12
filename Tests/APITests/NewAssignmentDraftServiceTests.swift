// Tests/APITests/NewAssignmentDraftServiceTests.swift
//
// Unit tests for the per-action service that backs
// `POST /instructor/new/draft`.  These tests construct the service
// directly (no HTTP layer, no CSRF, no multipart body) and call each
// action method individually, then assert on `setup` / `formState`.
//
// This is the win from moving the action dispatcher off the route
// handler: each action becomes testable in isolation in
// ~10-20 lines of fixture setup rather than a full multipart
// integration test.  The end-to-end happy path is still exercised
// by `AssignmentRoutesPublishTests`.
//
// The service still depends on `Request` (for filesystem + db +
// logger), so these tests use a synthetic `Request` from a test
// `Application`.  That's a heavier setUp than truly Vapor-free unit
// tests, but a clean improvement on the previous "spin up the whole
// HTTP stack to test one validation branch" pattern.

import Fluent
import Foundation
import Testing
import Vapor
import XCTVapor

@testable import APIServer

@Suite(.serialized) final class NewAssignmentDraftServiceTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-draft-svc")
    }

    // MARK: - Fixture helpers

    private func makeSyntheticRequest() -> Request {
        Request(application: app, on: app.eventLoopGroup.next())
    }

    private func sampleNotebookData(marker: String = "marker") -> Data {
        let json = """
            {
              "cells": [
                {"cell_type": "code", "source": ["# \(marker)\\n"], "metadata": {}, "outputs": [], "execution_count": null}
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
        assignmentNotebookFile: File? = nil,
        solutionNotebookFile: File? = nil,
        suiteFiles: [File] = []
    ) -> NewAssignmentDraftPayload {
        NewAssignmentDraftPayload(
            assignmentName: "Test Assignment",
            dueAt: "",
            startsAt: "",
            sectionIDRaw: "",
            draftIDRaw: nil,
            action: action,
            assignmentNotebookFile: assignmentNotebookFile,
            solutionNotebookFile: solutionNotebookFile,
            suiteFiles: suiteFiles,
            suiteConfigRaw: nil,
            requiredPlatform: "",
            requiredArchitecture: "",
            requiredLanguagesCSV: "",
            requiredCapabilitiesCSV: ""
        )
    }

    @discardableResult
    private func insertCourseAndDraftSetup(id: String) async throws -> (UUID, APITestSetup) {
        let courseID = try await app.testCourseID(code: "DSVC101", name: "Draft Svc Course")
        let manifest = """
            {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
            """
        let zipPath = app.testSetupsDirectory + "\(id).zip"
        // Ensure parent exists; an empty file is fine for actions that
        // don't actually re-read the zip.
        try FileManager.default.createDirectory(
            atPath: app.testSetupsDirectory, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: zipPath))

        let setup = APITestSetup(
            id: id, manifest: manifest, zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        return (courseID, setup)
    }

    private func makeService(
        courseID: UUID,
        setup: APITestSetup,
        payload: NewAssignmentDraftPayload
    ) -> NewAssignmentDraftService {
        NewAssignmentDraftService(
            req: makeSyntheticRequest(),
            setup: setup,
            setupID: setup.id ?? "",
            userID: UUID(),
            courseID: courseID,
            formState: NewAssignmentDraftFormState.empty,
            payload: payload
        )
    }

    // MARK: - createAssignmentNotebook

    @Test func createAssignmentNotebookWritesFileAndUpdatesFormState() async throws {
        try await withApp(app) { _ in
            let (courseID, setup) = try await insertCourseAndDraftSetup(id: "svc_create_an1")
            var service = makeService(
                courseID: courseID, setup: setup,
                payload: makePayload(action: "create-assignment-notebook"))

            let outcome = try await service.perform()

            #expect(outcome == .applied)
            #expect(service.formState.assignmentNotebookName == "assignment.ipynb")
            #expect(setup.notebookPath != nil)
            if let path = setup.notebookPath {
                #expect(
                    FileManager.default.fileExists(atPath: path),
                    "expected default notebook on disk at \(path)")
            }

        }
    }

    // MARK: - uploadAssignmentNotebook (validation branches)

    @Test func uploadAssignmentNotebookReturnsValidationFailedWhenFileMissing() async throws {
        try await withApp(app) { _ in
            let (courseID, setup) = try await insertCourseAndDraftSetup(id: "svc_upload_an_missing")
            var service = makeService(
                courseID: courseID, setup: setup,
                payload: makePayload(action: "upload-assignment-notebook"))

            let outcome = try await service.perform()

            #expect(outcome == .validationFailed("Select an assignment notebook to upload"))
            #expect(service.formState.assignmentNotebookName == nil)
            #expect(setup.notebookPath == nil)

        }
    }

    @Test func uploadAssignmentNotebookReturnsValidationFailedWhenJSONInvalid() async throws {
        try await withApp(app) { _ in
            let (courseID, setup) = try await insertCourseAndDraftSetup(id: "svc_upload_an_badjson")
            let badFile = makeFile(named: "garbage.ipynb", contents: Data("not json at all".utf8))
            var service = makeService(
                courseID: courseID, setup: setup,
                payload: makePayload(action: "upload-assignment-notebook", assignmentNotebookFile: badFile))

            let outcome = try await service.perform()

            #expect(outcome == .validationFailed("Assignment notebook must be valid JSON (.ipynb)"))
            #expect(setup.notebookPath == nil)

        }
    }

    @Test func uploadAssignmentNotebookPersistsValidNotebook() async throws {
        try await withApp(app) { _ in
            let (courseID, setup) = try await insertCourseAndDraftSetup(id: "svc_upload_an_ok")
            let nb = sampleNotebookData(marker: "uploaded-marker")
            let file = makeFile(named: "my-lab.ipynb", contents: nb)
            var service = makeService(
                courseID: courseID, setup: setup,
                payload: makePayload(action: "upload-assignment-notebook", assignmentNotebookFile: file))

            let outcome = try await service.perform()

            #expect(outcome == .applied)
            #expect(service.formState.assignmentNotebookName == "my-lab.ipynb")
            #expect(setup.notebookPath != nil)
            if let path = setup.notebookPath {
                let onDisk = try Data(contentsOf: URL(fileURLWithPath: path))
                #expect(
                    String(data: onDisk, encoding: .utf8)?.contains("uploaded-marker") == true,
                    "expected uploaded marker to survive normalization")
            }

        }
    }

    // MARK: - clearAssignmentNotebook

    @Test func clearAssignmentNotebookResetsNotebookPath() async throws {
        try await withApp(app) { _ in
            let (courseID, setup) = try await insertCourseAndDraftSetup(id: "svc_clear_an")
            // First create the notebook so there's something to clear.
            let createPayload = makePayload(action: "create-assignment-notebook")
            var createSvc = makeService(courseID: courseID, setup: setup, payload: createPayload)
            _ = try await createSvc.perform()
            #expect(setup.notebookPath != nil, "preconditions: notebook must exist before clear")

            // Now clear.
            var clearSvc = makeService(
                courseID: courseID, setup: setup,
                payload: makePayload(action: "clear-assignment-notebook"))
            let outcome = try await clearSvc.perform()

            #expect(outcome == .applied)
            #expect(setup.notebookPath == nil)
            #expect(clearSvc.formState.assignmentNotebookName == nil)

        }
    }

    // MARK: - uploadSolutionNotebook (validation branches)

    @Test func uploadSolutionNotebookReturnsValidationFailedWhenFileMissing() async throws {
        try await withApp(app) { _ in
            let (courseID, setup) = try await insertCourseAndDraftSetup(id: "svc_upload_sn_missing")
            var service = makeService(
                courseID: courseID, setup: setup,
                payload: makePayload(action: "upload-solution-notebook"))

            let outcome = try await service.perform()

            #expect(outcome == .validationFailed("Select a solution notebook to upload"))

        }
    }

    @Test func uploadSolutionNotebookReturnsValidationFailedWhenJSONInvalid() async throws {
        try await withApp(app) { _ in
            let (courseID, setup) = try await insertCourseAndDraftSetup(id: "svc_upload_sn_badjson")
            let badFile = makeFile(named: "junk.ipynb", contents: Data("nope".utf8))
            var service = makeService(
                courseID: courseID, setup: setup,
                payload: makePayload(action: "upload-solution-notebook", solutionNotebookFile: badFile))

            let outcome = try await service.perform()

            #expect(outcome == .validationFailed("Solution notebook must be valid JSON (.ipynb)"))

        }
    }

    // MARK: - Unknown / empty action

    @Test func unknownActionIsNoOpReturningApplied() async throws {
        try await withApp(app) { _ in
            let (courseID, setup) = try await insertCourseAndDraftSetup(id: "svc_unknown")
            var service = makeService(
                courseID: courseID, setup: setup,
                payload: makePayload(action: "totally-not-a-real-action"))

            let outcome = try await service.perform()

            #expect(outcome == .applied)
            #expect(setup.notebookPath == nil)
            #expect(service.formState.assignmentNotebookName == nil)

        }
    }

    @Test func emptyActionIsNoOpReturningApplied() async throws {
        try await withApp(app) { _ in
            let (courseID, setup) = try await insertCourseAndDraftSetup(id: "svc_empty")
            var service = makeService(
                courseID: courseID, setup: setup,
                payload: makePayload(action: ""))

            let outcome = try await service.perform()

            #expect(outcome == .applied)

        }
    }

    // MARK: - notebookTitle derivation

    @Test func notebookTitleFallsBackToPlaceholderWhenAssignmentNameEmpty() async throws {
        try await withApp(app) { _ in
            let payload = NewAssignmentDraftPayload(
                assignmentName: "  ", dueAt: "", startsAt: "", sectionIDRaw: "",
                draftIDRaw: nil, action: "",
                assignmentNotebookFile: nil, solutionNotebookFile: nil,
                suiteFiles: [], suiteConfigRaw: nil,
                requiredPlatform: "", requiredArchitecture: "",
                requiredLanguagesCSV: "", requiredCapabilitiesCSV: "")
            let service = NewAssignmentDraftService(
                req: makeSyntheticRequest(),
                setup: APITestSetup(id: "x", manifest: "{}", zipPath: "/tmp/x", courseID: UUID()),
                setupID: "x", userID: UUID(), courseID: UUID(),
                formState: NewAssignmentDraftFormState.empty, payload: payload)

            #expect(service.notebookTitle == "New Assignment")

        }
    }

    @Test func notebookTitleUsesTrimmedAssignmentNameWhenSet() async throws {
        try await withApp(app) { _ in
            let payload = NewAssignmentDraftPayload(
                assignmentName: "  Linked Lists  ", dueAt: "", startsAt: "", sectionIDRaw: "",
                draftIDRaw: nil, action: "",
                assignmentNotebookFile: nil, solutionNotebookFile: nil,
                suiteFiles: [], suiteConfigRaw: nil,
                requiredPlatform: "", requiredArchitecture: "",
                requiredLanguagesCSV: "", requiredCapabilitiesCSV: "")
            let service = NewAssignmentDraftService(
                req: makeSyntheticRequest(),
                setup: APITestSetup(id: "x", manifest: "{}", zipPath: "/tmp/x", courseID: UUID()),
                setupID: "x", userID: UUID(), courseID: UUID(),
                formState: NewAssignmentDraftFormState.empty, payload: payload)

            #expect(service.notebookTitle == "Linked Lists")

        }
    }
}
