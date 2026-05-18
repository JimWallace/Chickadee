// Tests/APITests/AssignmentRoutesEditorTests.swift
//
// Integration tests for the instructor assignment-editor handlers that
// were not directly covered before this file: the three file-download
// endpoints (notebook, generic setup item, solution) plus the
// create-solution helper.  Script CRUD lives in ScriptEditRoutesTests
// and the save flow lives in AssignmentRoutesPublishTests; this file
// fills the editor-coverage gap flagged in the architecture review.
//
//   GET  /instructor/:assignmentID/files/notebook
//   GET  /instructor/:assignmentID/files/item?name=<filename>
//   GET  /instructor/:assignmentID/files/solution
//   POST /instructor/:assignmentID/create-solution

import Fluent
import Foundation
import XCTVapor
import XCTest

@testable import chickadee_server

final class AssignmentRoutesEditorTests: XCTestCase {

    private var app: Application!

    override func setUp() async throws {
        app = try await makeTestApp(prefix: "chickadee-editor")
    }

    override func tearDown() async throws {
        try await app.tearDownTestApp()
    }

    // MARK: - Auth helpers

    private func loginAsInstructor() async throws -> String {
        try await loginUser(
            username: "testinstructor_editor", password: "testpassword",
            role: "instructor", on: app)
    }

    private func loginAsStudent() async throws -> String {
        try await loginUser(
            username: "teststudent_editor", password: "testpassword",
            role: "student", on: app)
    }

    // MARK: - DB / fixture helpers

    /// Minimal notebook JSON the JupyterLite normalizer accepts.
    private func sampleNotebookData(marker: String = "marker") -> Data {
        let json = """
            {
              "cells": [
                {
                  "cell_type": "code",
                  "source": ["# \(marker)\\n"],
                  "metadata": {},
                  "outputs": [],
                  "execution_count": null
                }
              ],
              "metadata": {
                "kernelspec": { "name": "python3", "display_name": "Python 3" },
                "language_info": { "name": "python" }
              },
              "nbformat": 4,
              "nbformat_minor": 5
            }
            """
        return Data(json.utf8)
    }

    /// Creates a zip at `zipPath` via the system `zip` CLI (matches the
    /// pattern in ScriptEditRoutesTests so the same skip-on-missing-tooling
    /// guard applies).
    private func makeZipAt(zipPath: String, entries: [(name: String, content: Data)]) throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/zip"),
            FileManager.default.fileExists(atPath: "/usr/bin/unzip")
        else { throw XCTSkip("zip/unzip not available") }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-editor-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for entry in entries {
            try entry.content.write(to: tempDir.appendingPathComponent(entry.name))
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = tempDir
        proc.arguments = ["-q", "-r", zipPath, "."]
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, "zip should succeed")
    }

    @discardableResult
    private func insertSetup(
        id: String,
        notebookOnDisk: Data? = nil,
        zipEntries: [(name: String, content: Data)] = []
    ) async throws -> APITestSetup {
        let courseID = try await app.testCourseID(code: "EDIT101", name: "Editor Test Course")
        let manifest = """
            {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
            """
        let zipPath = app.testSetupsDirectory + "\(id).zip"
        let starter =
            zipEntries.isEmpty
            ? [("placeholder.txt", Data("placeholder\n".utf8))]
            : zipEntries
        try makeZipAt(zipPath: zipPath, entries: starter)

        var notebookPath: String?
        if let nb = notebookOnDisk {
            let path = app.testSetupsDirectory + "\(id).ipynb"
            try nb.write(to: URL(fileURLWithPath: path))
            notebookPath = path
        }

        let setup = APITestSetup(
            id: id,
            manifest: manifest,
            zipPath: zipPath,
            notebookPath: notebookPath,
            courseID: courseID
        )
        try await setup.save(on: app.db)
        return setup
    }

    @discardableResult
    private func insertAssignment(testSetupID: String, title: String) async throws -> APIAssignment {
        let courseID = try await app.testCourseID(code: "EDIT101", name: "Editor Test Course")
        let a = APIAssignment(
            testSetupID: testSetupID, title: title, dueAt: nil, isOpen: true,
            courseID: courseID)
        try await a.save(on: app.db)
        return a
    }

    // MARK: - GET /instructor/:assignmentID/files/notebook

    func testDownloadNotebookFileReturnsNotebookBytes() async throws {
        let cookie = try await loginAsInstructor()
        let nb = sampleNotebookData(marker: "starter")
        try await insertSetup(id: "ed_nb1", notebookOnDisk: nb)
        let a = try await insertAssignment(testSetupID: "ed_nb1", title: "Lab 1")

        try await app.asyncTest(
            .GET, "/instructor/\(a.publicID)/files/notebook",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                // notebookData(for:) normalises before returning, so we can't
                // byte-compare — but the unique marker we put in must survive.
                XCTAssertTrue(
                    res.body.string.contains("starter"),
                    "Expected normalised notebook to contain marker; got prefix: \(res.body.string.prefix(160))")
                XCTAssertNotNil(res.headers["Content-Disposition"].first)
            })
    }

    func testDownloadNotebookFileReturns403ForStudent() async throws {
        let cookie = try await loginAsStudent()
        try await insertSetup(id: "ed_nb2", notebookOnDisk: sampleNotebookData())
        let a = try await insertAssignment(testSetupID: "ed_nb2", title: "Lab 2")

        try await app.asyncTest(
            .GET, "/instructor/\(a.publicID)/files/notebook",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .forbidden)
            })
    }

    func testDownloadNotebookFileReturns404ForUnknownAssignment() async throws {
        let cookie = try await loginAsInstructor()

        try await app.asyncTest(
            .GET, "/instructor/zzzzzz/files/notebook",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            })
    }

    // MARK: - GET /instructor/:assignmentID/files/item?name=<filename>

    func testDownloadSetupItemReturnsFileContent() async throws {
        let cookie = try await loginAsInstructor()
        try await insertSetup(
            id: "ed_item1",
            zipEntries: [("data.csv", Data("col1,col2\n1,2\n".utf8))])
        let a = try await insertAssignment(testSetupID: "ed_item1", title: "Lab 3")

        try await app.asyncTest(
            .GET, "/instructor/\(a.publicID)/files/item?name=data.csv",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(res.body.string.contains("col1,col2"))
            })
    }

    func testDownloadSetupItemReturns404ForMissingFile() async throws {
        let cookie = try await loginAsInstructor()
        try await insertSetup(id: "ed_item2")
        let a = try await insertAssignment(testSetupID: "ed_item2", title: "Lab 4")

        try await app.asyncTest(
            .GET, "/instructor/\(a.publicID)/files/item?name=missing.txt",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            })
    }

    /// Path-traversal guard: anything that isn't a pure filename (e.g.
    /// "../etc/passwd", "subdir/x") is rejected at the handler level.
    func testDownloadSetupItemRejectsPathTraversal() async throws {
        let cookie = try await loginAsInstructor()
        try await insertSetup(id: "ed_item3")
        let a = try await insertAssignment(testSetupID: "ed_item3", title: "Lab 5")

        try await app.asyncTest(
            .GET, "/instructor/\(a.publicID)/files/item?name=../etc/passwd",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .badRequest)
            })
    }

    func testDownloadSetupItemReturns403ForStudent() async throws {
        let cookie = try await loginAsStudent()
        try await insertSetup(id: "ed_item4")
        let a = try await insertAssignment(testSetupID: "ed_item4", title: "Lab 6")

        try await app.asyncTest(
            .GET, "/instructor/\(a.publicID)/files/item?name=anything.txt",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .forbidden)
            })
    }

    // MARK: - GET /instructor/:assignmentID/files/solution

    func testDownloadSolutionFileReturnsZipEntry() async throws {
        let cookie = try await loginAsInstructor()
        let solution = sampleNotebookData(marker: "solution-payload")
        try await insertSetup(
            id: "ed_sol1",
            zipEntries: [("solution.ipynb", solution)])
        let a = try await insertAssignment(testSetupID: "ed_sol1", title: "Lab 7")

        try await app.asyncTest(
            .GET, "/instructor/\(a.publicID)/files/solution",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(
                    res.body.string.contains("solution-payload"),
                    "Expected solution marker in response body")
            })
    }

    func testDownloadSolutionFileReturns404WhenNoSolutionExists() async throws {
        let cookie = try await loginAsInstructor()
        try await insertSetup(id: "ed_sol2")  // no solution.* entry
        let a = try await insertAssignment(testSetupID: "ed_sol2", title: "Lab 8")

        try await app.asyncTest(
            .GET, "/instructor/\(a.publicID)/files/solution",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            })
    }

    func testDownloadSolutionFileReturns403ForStudent() async throws {
        let cookie = try await loginAsStudent()
        try await insertSetup(
            id: "ed_sol3",
            zipEntries: [("solution.ipynb", sampleNotebookData())])
        let a = try await insertAssignment(testSetupID: "ed_sol3", title: "Lab 9")

        try await app.asyncTest(
            .GET, "/instructor/\(a.publicID)/files/solution",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .forbidden)
            })
    }

    // MARK: - POST /instructor/:assignmentID/create-solution

    func testCreateSolutionFromAssignmentReturns403ForStudent() async throws {
        let cookie = try await loginAsStudent()
        try await insertSetup(id: "ed_csol1", notebookOnDisk: sampleNotebookData())
        let a = try await insertAssignment(testSetupID: "ed_csol1", title: "Lab 10")

        try await app.asyncTest(
            .POST, "/instructor/\(a.publicID)/create-solution",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .forbidden)
            })
    }

    func testCreateSolutionFromAssignmentReturns404ForUnknownAssignment() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        try await app.asyncTest(
            .POST, "/instructor/zzzzzz/create-solution",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            })
    }
}
