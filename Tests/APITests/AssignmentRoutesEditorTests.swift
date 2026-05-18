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
import Testing
import XCTVapor

@testable import chickadee_server

@Suite(.serialized) final class AssignmentRoutesEditorTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-editor")
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
        else { Issue.record("skipped: " + "zip/unzip not available"); return }

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
        #expect(proc.terminationStatus == 0, "zip should succeed")
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

    @Test func downloadNotebookFileReturnsNotebookBytes() async throws {
        try await withApp(app) { _ in
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
                    #expect(res.status == .ok)
                    // notebookData(for:) normalises before returning, so we can't
                    // byte-compare — but the unique marker we put in must survive.
                    #expect(
                        res.body.string.contains("starter"),
                        "Expected normalised notebook to contain marker; got prefix: \(res.body.string.prefix(160))")
                    #expect(res.headers["Content-Disposition"].first != nil)
                })

        }
    }

    @Test func downloadNotebookFileReturns403ForStudent() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent()
            try await insertSetup(id: "ed_nb2", notebookOnDisk: sampleNotebookData())
            let a = try await insertAssignment(testSetupID: "ed_nb2", title: "Lab 2")

            try await app.asyncTest(
                .GET, "/instructor/\(a.publicID)/files/notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

        }
    }

    @Test func downloadNotebookFileReturns404ForUnknownAssignment() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsInstructor()

            try await app.asyncTest(
                .GET, "/instructor/zzzzzz/files/notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }

    // MARK: - GET /instructor/:assignmentID/files/item?name=<filename>

    @Test func downloadSetupItemReturnsFileContent() async throws {
        try await withApp(app) { _ in
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
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("col1,col2"))
                })

        }
    }

    @Test func downloadSetupItemReturns404ForMissingFile() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsInstructor()
            try await insertSetup(id: "ed_item2")
            let a = try await insertAssignment(testSetupID: "ed_item2", title: "Lab 4")

            try await app.asyncTest(
                .GET, "/instructor/\(a.publicID)/files/item?name=missing.txt",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }

    /// Path-traversal guard: anything that isn't a pure filename (e.g.
    /// "../etc/passwd", "subdir/x") is rejected at the handler level.
    @Test func downloadSetupItemRejectsPathTraversal() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsInstructor()
            try await insertSetup(id: "ed_item3")
            let a = try await insertAssignment(testSetupID: "ed_item3", title: "Lab 5")

            try await app.asyncTest(
                .GET, "/instructor/\(a.publicID)/files/item?name=../etc/passwd",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                })

        }
    }

    @Test func downloadSetupItemReturns403ForStudent() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent()
            try await insertSetup(id: "ed_item4")
            let a = try await insertAssignment(testSetupID: "ed_item4", title: "Lab 6")

            try await app.asyncTest(
                .GET, "/instructor/\(a.publicID)/files/item?name=anything.txt",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

        }
    }

    // MARK: - GET /instructor/:assignmentID/files/solution

    @Test func downloadSolutionFileReturnsZipEntry() async throws {
        try await withApp(app) { _ in
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
                    #expect(res.status == .ok)
                    #expect(
                        res.body.string.contains("solution-payload"),
                        "Expected solution marker in response body")
                })

        }
    }

    @Test func downloadSolutionFileReturns404WhenNoSolutionExists() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsInstructor()
            try await insertSetup(id: "ed_sol2")  // no solution.* entry
            let a = try await insertAssignment(testSetupID: "ed_sol2", title: "Lab 8")

            try await app.asyncTest(
                .GET, "/instructor/\(a.publicID)/files/solution",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }

    @Test func downloadSolutionFileReturns403ForStudent() async throws {
        try await withApp(app) { _ in
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
                    #expect(res.status == .forbidden)
                })

        }
    }

    // MARK: - POST /instructor/:assignmentID/create-solution

    @Test func createSolutionFromAssignmentReturns403ForStudent() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent()
            try await insertSetup(id: "ed_csol1", notebookOnDisk: sampleNotebookData())
            let a = try await insertAssignment(testSetupID: "ed_csol1", title: "Lab 10")

            try await app.asyncTest(
                .POST, "/instructor/\(a.publicID)/create-solution",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

        }
    }

    @Test func createSolutionFromAssignmentReturns404ForUnknownAssignment() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsInstructor()
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/zzzzzz/create-solution",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }

    // MARK: - GET /instructor/new/draft/solution-notebook
    //
    // The draft solution endpoint reads from one of two locations: a
    // per-user working copy under `Public/jupyterlite/files/...`, or a
    // fallback path at `<testSetupsDirectory>/notebooks/<setupID>/solution.ipynb`.
    // These tests exercise the fallback path because it doesn't require
    // the JupyterLite directory layout to be present in the test fixture.

    private func writeDraftSolutionNotebook(setupID: String, data: Data) throws {
        let dir = app.testSetupsDirectory + "notebooks/\(setupID)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: dir + "solution.ipynb"))
    }

    @Test func draftSolutionNotebookReturnsNotebookBytes() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsInstructor()
            let setup = try await insertSetup(id: "ed_draft_sol1")
            try writeDraftSolutionNotebook(
                setupID: setup.id ?? "",
                data: sampleNotebookData(marker: "draft-solution-marker"))

            try await app.asyncTest(
                .GET, "/instructor/new/draft/solution-notebook?draftID=\(setup.id ?? "")",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.headers.contentType?.description == "application/json")
                    #expect(
                        res.body.string.contains("draft-solution-marker"),
                        "Expected marker in draft solution body; got: \(res.body.string.prefix(200))")
                })

        }
    }

    @Test func draftSolutionNotebookReturns404ForUnknownDraft() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsInstructor()

            try await app.asyncTest(
                .GET, "/instructor/new/draft/solution-notebook?draftID=ZZZ_does_not_exist",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }

    @Test func draftSolutionNotebookReturns404ForDraftWithoutSolutionFile() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsInstructor()
            let setup = try await insertSetup(id: "ed_draft_sol2")
            // intentionally do NOT write the solution.ipynb fallback file
            try await app.asyncTest(
                .GET, "/instructor/new/draft/solution-notebook?draftID=\(setup.id ?? "")",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }

    @Test func draftSolutionNotebookReturns404ForMissingDraftIDParam() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsInstructor()

            try await app.asyncTest(
                .GET, "/instructor/new/draft/solution-notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    // The handler treats absent / empty draftID as "no such draft."
                    #expect(res.status == .notFound)
                })

        }
    }

    @Test func draftSolutionNotebookReturns403ForStudent() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent()
            let setup = try await insertSetup(id: "ed_draft_sol3")
            try writeDraftSolutionNotebook(
                setupID: setup.id ?? "", data: sampleNotebookData())

            try await app.asyncTest(
                .GET, "/instructor/new/draft/solution-notebook?draftID=\(setup.id ?? "")",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

        }
    }

    // MARK: - POST /instructor/:assignmentID/edit/save
    //
    // The handler's happy path requires a multipart body with notebook
    // uploads + a non-empty manifest + a validation pipeline, which is
    // already exercised end-to-end by AssignmentRoutesPublishTests.
    // These tests pin the *validation-failure* redirect branches that
    // are not otherwise covered: empty title, invalid notebook JSON,
    // missing test suites — plus the auth and unknown-assignment cases.

    @Test func saveEditedAssignmentReturns403ForStudent() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent()
            try await insertSetup(id: "ed_save1")
            let a = try await insertAssignment(testSetupID: "ed_save1", title: "Lab Save 1")

            try await app.asyncTest(
                .POST, "/instructor/\(a.publicID)/edit/save",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

        }
    }

    @Test func saveEditedAssignmentReturns404ForUnknownAssignment() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsInstructor()
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/zzzzzz/edit/save",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["_csrf": csrf, "assignmentName": "Anything", "dueAt": ""],
                        as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }

    @Test func saveEditedAssignmentRedirectsWithErrorOnEmptyTitle() async throws {
        try await withApp(app) { _ in
            // CSRF fetched BEFORE creating the course-bearing fixtures: once a
            // course exists but the instructor isn't enrolled in it,
            // `GET /instructor` redirects to `/enroll` and the token extractor
            // returns an empty string.  Token issuance is session-scoped, not
            // path-scoped, so the early fetch is still valid for the POST.
            let cookie = try await loginAsInstructor()
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await insertSetup(id: "ed_save2", notebookOnDisk: sampleNotebookData())
            let a = try await insertAssignment(testSetupID: "ed_save2", title: "Original Title")

            try await app.asyncTest(
                .POST, "/instructor/\(a.publicID)/edit/save",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["_csrf": csrf, "assignmentName": "  ", "dueAt": ""],
                        as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    let location = res.headers["Location"].first ?? ""
                    #expect(
                        location.contains("error=Assignment%20name%20is%20required"),
                        "Expected error query string in redirect; got: \(location)")
                    #expect(
                        location.contains("/instructor/\(a.publicID)/edit"),
                        "Expected redirect back to edit page; got: \(location)")
                })

        }
    }

    @Test func saveEditedAssignmentRedirectsWithErrorOnMissingTestSuites() async throws {
        try await withApp(app) { _ in
            // Manifest has empty `testSuites: []` (see `insertSetup`), so the
            // "at least one test script" guard should fire and redirect.
            let cookie = try await loginAsInstructor()
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await insertSetup(id: "ed_save3", notebookOnDisk: sampleNotebookData())
            let a = try await insertAssignment(testSetupID: "ed_save3", title: "Lab Save 3")

            try await app.asyncTest(
                .POST, "/instructor/\(a.publicID)/edit/save",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["_csrf": csrf, "assignmentName": "Lab Save 3", "dueAt": ""],
                        as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    let location = res.headers["Location"].first ?? ""
                    #expect(
                        location.contains("error="),
                        "Expected error query string in redirect; got: \(location)")
                })

        }
    }
}
