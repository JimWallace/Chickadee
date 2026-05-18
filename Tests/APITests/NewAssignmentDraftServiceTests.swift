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
import Vapor
import XCTVapor
import XCTest

@testable import chickadee_server

final class NewAssignmentDraftServiceTests: XCTestCase {

    private var app: Application!

    override func setUp() async throws {
        app = try await makeTestApp(prefix: "chickadee-draft-svc")
    }

    override func tearDown() async throws {
        try await app.tearDownTestApp()
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

    func testCreateAssignmentNotebookWritesFileAndUpdatesFormState() async throws {
        let (courseID, setup) = try await insertCourseAndDraftSetup(id: "svc_create_an1")
        var service = makeService(
            courseID: courseID, setup: setup,
            payload: makePayload(action: "create-assignment-notebook"))

        let outcome = try await service.perform()

        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(service.formState.assignmentNotebookName, "assignment.ipynb")
        XCTAssertNotNil(setup.notebookPath)
        if let path = setup.notebookPath {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: path),
                "expected default notebook on disk at \(path)")
        }
    }

    // MARK: - uploadAssignmentNotebook (validation branches)

    func testUploadAssignmentNotebookReturnsValidationFailedWhenFileMissing() async throws {
        let (courseID, setup) = try await insertCourseAndDraftSetup(id: "svc_upload_an_missing")
        var service = makeService(
            courseID: courseID, setup: setup,
            payload: makePayload(action: "upload-assignment-notebook"))

        let outcome = try await service.perform()

        XCTAssertEqual(outcome, .validationFailed("Select an assignment notebook to upload"))
        XCTAssertNil(service.formState.assignmentNotebookName)
        XCTAssertNil(setup.notebookPath)
    }

    func testUploadAssignmentNotebookReturnsValidationFailedWhenJSONInvalid() async throws {
        let (courseID, setup) = try await insertCourseAndDraftSetup(id: "svc_upload_an_badjson")
        let badFile = makeFile(named: "garbage.ipynb", contents: Data("not json at all".utf8))
        var service = makeService(
            courseID: courseID, setup: setup,
            payload: makePayload(action: "upload-assignment-notebook", assignmentNotebookFile: badFile))

        let outcome = try await service.perform()

        XCTAssertEqual(
            outcome, .validationFailed("Assignment notebook must be valid JSON (.ipynb)"))
        XCTAssertNil(setup.notebookPath)
    }

    func testUploadAssignmentNotebookPersistsValidNotebook() async throws {
        let (courseID, setup) = try await insertCourseAndDraftSetup(id: "svc_upload_an_ok")
        let nb = sampleNotebookData(marker: "uploaded-marker")
        let file = makeFile(named: "my-lab.ipynb", contents: nb)
        var service = makeService(
            courseID: courseID, setup: setup,
            payload: makePayload(action: "upload-assignment-notebook", assignmentNotebookFile: file))

        let outcome = try await service.perform()

        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(service.formState.assignmentNotebookName, "my-lab.ipynb")
        XCTAssertNotNil(setup.notebookPath)
        if let path = setup.notebookPath {
            let onDisk = try Data(contentsOf: URL(fileURLWithPath: path))
            XCTAssertTrue(
                String(data: onDisk, encoding: .utf8)?.contains("uploaded-marker") == true,
                "expected uploaded marker to survive normalization")
        }
    }

    // MARK: - clearAssignmentNotebook

    func testClearAssignmentNotebookResetsNotebookPath() async throws {
        let (courseID, setup) = try await insertCourseAndDraftSetup(id: "svc_clear_an")
        // First create the notebook so there's something to clear.
        let createPayload = makePayload(action: "create-assignment-notebook")
        var createSvc = makeService(courseID: courseID, setup: setup, payload: createPayload)
        _ = try await createSvc.perform()
        XCTAssertNotNil(setup.notebookPath, "preconditions: notebook must exist before clear")

        // Now clear.
        var clearSvc = makeService(
            courseID: courseID, setup: setup,
            payload: makePayload(action: "clear-assignment-notebook"))
        let outcome = try await clearSvc.perform()

        XCTAssertEqual(outcome, .applied)
        XCTAssertNil(setup.notebookPath)
        XCTAssertNil(clearSvc.formState.assignmentNotebookName)
    }

    // MARK: - uploadSolutionNotebook (validation branches)

    func testUploadSolutionNotebookReturnsValidationFailedWhenFileMissing() async throws {
        let (courseID, setup) = try await insertCourseAndDraftSetup(id: "svc_upload_sn_missing")
        var service = makeService(
            courseID: courseID, setup: setup,
            payload: makePayload(action: "upload-solution-notebook"))

        let outcome = try await service.perform()

        XCTAssertEqual(outcome, .validationFailed("Select a solution notebook to upload"))
    }

    func testUploadSolutionNotebookReturnsValidationFailedWhenJSONInvalid() async throws {
        let (courseID, setup) = try await insertCourseAndDraftSetup(id: "svc_upload_sn_badjson")
        let badFile = makeFile(named: "junk.ipynb", contents: Data("nope".utf8))
        var service = makeService(
            courseID: courseID, setup: setup,
            payload: makePayload(action: "upload-solution-notebook", solutionNotebookFile: badFile))

        let outcome = try await service.perform()

        XCTAssertEqual(
            outcome, .validationFailed("Solution notebook must be valid JSON (.ipynb)"))
    }

    // MARK: - Unknown / empty action

    func testUnknownActionIsNoOpReturningApplied() async throws {
        let (courseID, setup) = try await insertCourseAndDraftSetup(id: "svc_unknown")
        var service = makeService(
            courseID: courseID, setup: setup,
            payload: makePayload(action: "totally-not-a-real-action"))

        let outcome = try await service.perform()

        XCTAssertEqual(outcome, .applied)
        XCTAssertNil(setup.notebookPath)
        XCTAssertNil(service.formState.assignmentNotebookName)
    }

    func testEmptyActionIsNoOpReturningApplied() async throws {
        let (courseID, setup) = try await insertCourseAndDraftSetup(id: "svc_empty")
        var service = makeService(
            courseID: courseID, setup: setup,
            payload: makePayload(action: ""))

        let outcome = try await service.perform()

        XCTAssertEqual(outcome, .applied)
    }

    // MARK: - notebookTitle derivation

    func testNotebookTitleFallsBackToPlaceholderWhenAssignmentNameEmpty() {
        let payload = NewAssignmentDraftPayload(
            assignmentName: "  ", dueAt: "", sectionIDRaw: "",
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

        XCTAssertEqual(service.notebookTitle, "New Assignment")
    }

    func testNotebookTitleUsesTrimmedAssignmentNameWhenSet() {
        let payload = NewAssignmentDraftPayload(
            assignmentName: "  Linked Lists  ", dueAt: "", sectionIDRaw: "",
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

        XCTAssertEqual(service.notebookTitle, "Linked Lists")
    }
}
