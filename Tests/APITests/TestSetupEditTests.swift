// Tests/APITests/TestSetupEditTests.swift
//
// Integration tests for Phase 8 notebook editor endpoints.
//
//   PUT  /api/v1/testsetups/:id/assignment  — save edited notebook
//   GET  /api/v1/testsetups/:id/assignment  — serves flat file when present
//   GET  /instructor/:id/edit              — instructor-only editor page

import Fluent
import Foundation
import Testing
import XCTVapor

@testable import chickadee_server

@Suite struct TestSetupEditTests {

    private func makeApp() async throws -> Application {
        let app = try await makeTestApp(prefix: "chickadee-edit")
        return app
    }

    // MARK: - Auth helpers

    private func loginAsInstructor(on app: Application) async throws -> String {
        return try await loginUser(
            username: "testinstructor_edit", password: "testpassword", role: "instructor", on: app)
    }

    private func loginAsStudent(on app: Application) async throws -> String {
        return try await loginUser(username: "teststudent_edit", password: "testpassword", role: "student", on: app)
    }

    // MARK: - Setup helpers

    /// Creates a test setup record in the DB (no real zip on disk).
    @discardableResult
    private func insertSetup(id: String, on app: Application) async throws -> APITestSetup {
        let manifest = """
            {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
            """
        let courseID = try await app.testCourseID()
        let setup = APITestSetup(
            id: id,
            manifest: manifest,
            zipPath: app.testSetupsDirectory + "\(id).zip",
            courseID: courseID
        )
        try await setup.save(on: app.db)
        return setup
    }

    @discardableResult
    private func insertAssignment(testSetupID: String, title: String, on app: Application) async throws -> APIAssignment
    {
        let courseID = try await app.testCourseID()
        let a = APIAssignment(testSetupID: testSetupID, title: title, dueAt: nil, isOpen: true, courseID: courseID)
        try await a.save(on: app.db)
        return a
    }

    // A minimal valid notebook JSON to use as test data.
    private let sampleNotebookJSON = """
        {
            "nbformat": 4,
            "nbformat_minor": 5,
            "metadata": {},
            "cells": [
                {
                    "cell_type": "code",
                    "source": ["# TEST: sample tier=public\\nassert 1 == 1"],
                    "metadata": {},
                    "outputs": []
                }
            ]
        }
        """

    private let python3NotebookJSON = """
        {
            "nbformat": 4,
            "nbformat_minor": 5,
            "metadata": {
                "kernelspec": {
                    "display_name": "Python 3 (ipykernel)",
                    "name": "python3"
                },
                "language_info": {
                    "name": "python"
                }
            },
            "cells": [
                {
                    "cell_type": "code",
                    "source": ["x = 1"],
                    "metadata": {},
                    "outputs": []
                }
            ]
        }
        """

    /// An R notebook exported from IRkernel (kernelspec.name = "ir").
    private let irNotebookJSON = """
        {
            "nbformat": 4,
            "nbformat_minor": 5,
            "metadata": {
                "kernelspec": {
                    "display_name": "R",
                    "language": "R",
                    "name": "ir"
                },
                "language_info": {
                    "name": "R"
                }
            },
            "cells": [
                {
                    "cell_type": "code",
                    "source": ["x <- 1"],
                    "metadata": {},
                    "outputs": []
                }
            ]
        }
        """

    // MARK: - PUT /api/v1/testsetups/:id/assignment

    @Test func putAssignmentSavesFileToDisk() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            try await insertSetup(id: "setup_put1", on: app)

            try await app.asyncTest(
                .PUT, "/api/v1/testsetups/setup_put1/assignment",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: sampleNotebookJSON)
                },
                afterResponse: { res in
                    #expect(res.status == .noContent)
                }
            )

            // File should be on disk.
            let expectedPath = app.testSetupsDirectory + "setup_put1.ipynb"
            #expect(
                FileManager.default.fileExists(atPath: expectedPath),
                "Expected flat .ipynb file at \(expectedPath)")

        }
    }

    @Test func putAssignmentUpdatesNotebookPathInDB() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            try await insertSetup(id: "setup_put2", on: app)

            try await app.asyncTest(
                .PUT, "/api/v1/testsetups/setup_put2/assignment",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: sampleNotebookJSON)
                },
                afterResponse: { res in
                    #expect(res.status == .noContent)
                }
            )

            let updated = try await APITestSetup.find("setup_put2", on: app.db)
            #expect(updated?.notebookPath != nil, "notebookPath should be set after PUT")
            #expect(updated?.notebookPath?.hasSuffix("setup_put2.ipynb") == true)

        }
    }

    @Test func putAssignmentNormalizesPython3KernelBeforeSaving() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            try await insertSetup(id: "setup_put_kernel", on: app)

            try await app.asyncTest(
                .PUT, "/api/v1/testsetups/setup_put_kernel/assignment",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: python3NotebookJSON)
                },
                afterResponse: { res in
                    #expect(res.status == .noContent)
                }
            )

            let expectedPath = app.testSetupsDirectory + "setup_put_kernel.ipynb"
            let savedData = try Data(contentsOf: URL(fileURLWithPath: expectedPath))
            let savedJSON = try JSONSerialization.jsonObject(with: savedData) as? [String: Any]
            let metadata = savedJSON?["metadata"] as? [String: Any]
            let kernelspec = metadata?["kernelspec"] as? [String: Any]
            #expect(kernelspec?["name"] as? String == "python")
            #expect(kernelspec?["display_name"] as? String == "Python (Pyodide)")

        }
    }

    @Test func getAssignmentServesFlatFileWhenPresent() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsInstructor(on: app)
            try await insertSetup(id: "setup_flat", on: app)

            // Write a flat notebook file directly.
            let flatPath = app.testSetupsDirectory + "setup_flat.ipynb"
            let editedJSON = """
                {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","source":["# edited"],"metadata":{},"outputs":[]}]}
                """
            try editedJSON.write(toFile: flatPath, atomically: true, encoding: .utf8)

            // Update DB record to point at the flat file.
            let setup = try #require(try await APITestSetup.find("setup_flat", on: app.db))
            setup.notebookPath = flatPath
            try await setup.save(on: app.db)

            // GET should return the flat file's content.
            try await app.asyncTest(
                .GET, "/api/v1/testsetups/setup_flat/assignment",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(
                        body.contains("# edited"),
                        "Expected flat file content, got: \(body.prefix(200))")
                }
            )

        }
    }

    @Test func getAssignmentNormalizesPython3KernelToPyodideKernel() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsInstructor(on: app)
            try await insertSetup(id: "setup_flat_kernel", on: app)

            let flatPath = app.testSetupsDirectory + "setup_flat_kernel.ipynb"
            try python3NotebookJSON.write(toFile: flatPath, atomically: true, encoding: .utf8)

            let setup = try #require(try await APITestSetup.find("setup_flat_kernel", on: app.db))
            setup.notebookPath = flatPath
            try await setup.save(on: app.db)

            try await app.asyncTest(
                .GET, "/api/v1/testsetups/setup_flat_kernel/assignment",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let data = Data(res.body.readableBytesView)
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let metadata = json?["metadata"] as? [String: Any]
                    let kernelspec = metadata?["kernelspec"] as? [String: Any]
                    #expect(kernelspec?["name"] as? String == "python")
                    #expect(kernelspec?["display_name"] as? String == "Python (Pyodide)")
                }
            )

        }
    }

    @Test func putAssignmentRejectsNonJSON() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            try await insertSetup(id: "setup_bad", on: app)

            try await app.asyncTest(
                .PUT, "/api/v1/testsetups/setup_bad/assignment",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: "this is not JSON!!!")
                },
                afterResponse: { res in
                    #expect(res.status == .unprocessableEntity)
                }
            )

        }
    }

    @Test func putAssignmentReturnsNotFoundForUnknownSetup() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

            try await app.asyncTest(
                .PUT, "/api/v1/testsetups/does_not_exist/assignment",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: sampleNotebookJSON)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                }
            )

        }
    }

    // MARK: - Role guard on PUT

    @Test func studentCannotPutAssignment() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsStudent(on: app)
            try await insertSetup(id: "setup_student_put", on: app)

            // Students are not on the instructor route group — middleware rejects them.
            try await app.asyncTest(
                .PUT, "/api/v1/testsetups/setup_student_put/assignment",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: sampleNotebookJSON)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                }
            )

        }
    }

    // MARK: - GET /instructor/:id/edit

    @Test func editPageRequiresInstructor() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsStudent(on: app)
            try await insertSetup(id: "setup_ep1", on: app)
            let a = try await insertAssignment(testSetupID: "setup_ep1", title: "Lab", on: app)
            let id = a.publicID

            try await app.asyncTest(
                .GET, "/instructor/\(id)/edit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                }
            )

        }
    }

    @Test func editPageNotFoundForUnknownAssignment() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsInstructor(on: app)
            let fakeID = "zzzzzz"

            try await app.asyncTest(
                .GET, "/instructor/\(fakeID)/edit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                }
            )

        }
    }

    @Test func editPageInstructorAccessGranted() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsInstructor(on: app)
            try await insertSetup(id: "setup_ep2", on: app)
            let a = try await insertAssignment(testSetupID: "setup_ep2", title: "My Lab", on: app)
            let id = a.publicID

            try await app.asyncTest(
                .GET, "/instructor/\(id)/edit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    // 500 is expected — Leaf not configured in tests — but middleware passed.
                    #expect(res.status != .unauthorized)
                    #expect(res.status != .forbidden)
                    #expect(res.status != .notFound)
                }
            )

        }
    }

    // MARK: - R kernel normalization (Issue #77)

    @Test func putAssignmentNormalizesIRKernelToWebR() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            try await insertSetup(id: "setup_put_ir", on: app)

            try await app.asyncTest(
                .PUT, "/api/v1/testsetups/setup_put_ir/assignment",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: irNotebookJSON)
                },
                afterResponse: { res in
                    #expect(res.status == .noContent)
                }
            )

            let expectedPath = app.testSetupsDirectory + "setup_put_ir.ipynb"
            let savedData = try Data(contentsOf: URL(fileURLWithPath: expectedPath))
            let savedJSON = try JSONSerialization.jsonObject(with: savedData) as? [String: Any]
            let metadata = savedJSON?["metadata"] as? [String: Any]
            let kernelspec = metadata?["kernelspec"] as? [String: Any]
            #expect(kernelspec?["name"] as? String == "webr", "ir kernel should be normalized to webr")
            #expect(kernelspec?["display_name"] as? String == "R (WebR)", "display_name should be R (WebR)")

        }
    }

    @Test func getAssignmentNormalizesIRKernelToWebR() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsInstructor(on: app)
            try await insertSetup(id: "setup_flat_ir", on: app)

            let flatPath = app.testSetupsDirectory + "setup_flat_ir.ipynb"
            try irNotebookJSON.write(toFile: flatPath, atomically: true, encoding: .utf8)

            let setup = try #require(try await APITestSetup.find("setup_flat_ir", on: app.db))
            setup.notebookPath = flatPath
            try await setup.save(on: app.db)

            try await app.asyncTest(
                .GET, "/api/v1/testsetups/setup_flat_ir/assignment",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let data = Data(res.body.readableBytesView)
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let metadata = json?["metadata"] as? [String: Any]
                    let kernelspec = metadata?["kernelspec"] as? [String: Any]
                    #expect(kernelspec?["name"] as? String == "webr", "ir kernel should be normalized to webr on GET")
                    #expect(
                        kernelspec?["display_name"] as? String == "R (WebR)", "display_name should be R (WebR) on GET")
                }
            )

        }
    }

    @Test func normalizationPreservesPythonKernelUnchanged() async throws {
        try await withApp(try await makeApp()) { app in
            // PUT a Python notebook and verify it still normalizes to Pyodide (not webr).
            let cookie = try await loginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            try await insertSetup(id: "setup_put_py_check", on: app)

            try await app.asyncTest(
                .PUT, "/api/v1/testsetups/setup_put_py_check/assignment",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: python3NotebookJSON)
                },
                afterResponse: { res in
                    #expect(res.status == .noContent)
                }
            )

            let expectedPath = app.testSetupsDirectory + "setup_put_py_check.ipynb"
            let savedData = try Data(contentsOf: URL(fileURLWithPath: expectedPath))
            let savedJSON = try JSONSerialization.jsonObject(with: savedData) as? [String: Any]
            let metadata = savedJSON?["metadata"] as? [String: Any]
            let kernelspec = metadata?["kernelspec"] as? [String: Any]
            #expect(kernelspec?["name"] as? String == "python", "python3 kernel should still normalize to python")
            #expect(
                kernelspec?["display_name"] as? String == "Python (Pyodide)",
                "display_name should still be Python (Pyodide)")

        }
    }
}
