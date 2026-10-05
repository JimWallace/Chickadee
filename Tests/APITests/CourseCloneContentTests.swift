// Tests/APITests/CourseCloneContentTests.swift
//
// The admin clone route copies every part of an assignment that
// `cloneAssignment` copies, and every course setting the clone keeps (#2170).
// `CourseCloneTests` pins the resets and the "not copied" list; the parts
// below were pinned only through direct calls or the MCP tool, so a
// regression in the course loop would have passed.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

private let supportManifest =
    #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"test_a.sh"}],"timeLimitSeconds":10}"#

private let starterNotebook = #"""
    {"nbformat":4,"nbformat_minor":5,"metadata":{"kernelspec":{"name":"xpython","language":"python"},"language_info":{"name":"python"}},"cells":[{"cell_type":"markdown","metadata":{},"source":["# Lab 1\n"]}]}
    """#

private let solutionNotebook = #"""
    {"nbformat":4,"nbformat_minor":5,"metadata":{"kernelspec":{"name":"xpython","language":"python"},"language_info":{"name":"python"}},"cells":[{"cell_type":"code","metadata":{},"source":["def answer():\n","    return 42\n"]}]}
    """#

/// Writes a setup zip holding one graded script and one support file.
private func writeSetupZip(at zipPath: String) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("clone-content-zip-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("exit 0\n".utf8).write(to: root.appendingPathComponent("test_a.sh"))
    try Data("pulse,diet\n80,low fat\n".utf8).write(to: root.appendingPathComponent("data.csv"))
    try await writeZipFixture(of: root, to: zipPath)
}

@Suite(.serialized, .timeLimit(.minutes(10))) final class CourseCloneContentTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-course-clone-content")
    }

    private func postClone(
        _ sourceID: UUID, form: [String: String], cookie: String
    ) async throws -> String? {
        let path = "/admin/courses/\(sourceID.uuidString)"
        let (token, boundCookie) = try await csrfFields(for: path, cookie: cookie, on: app)
        var fields = form
        fields["_csrf"] = token
        var location: String?
        try await app.asyncTest(
            .POST, path + "/clone",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(fields, as: .urlEncodedForm)
            },
            afterResponse: { res in
                #expect(res.status == .seeOther)
                location = res.headers.first(name: .location)
            })
        return location
    }

    /// One assignment with a starter notebook, a support file in its zip, a
    /// reference solution that exists only as a validation submission, and
    /// both policies the clone test leaves unset; a course with all four
    /// slip-day fields set away from their defaults.
    @Test func cloneCopiesEveryPartThroughTheRoute() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("clone_content_admin", on: app)
            let course = APICourse(
                code: "CLC1", name: "Content Source", enrollmentMode: .closed,
                term: AcademicTerm(year: 2026, season: .fall))
            course.slipDaysEnabled = true
            course.slipDaysPerStudent = 4
            course.slipDayExtensionHours = 36
            course.slipDayReleaseRevealHold = false
            try await course.save(on: app.db)
            let courseID = try course.requireID()

            let zipPath = app.testSetupsDirectory + "setup_clc_src.zip"
            try await writeSetupZip(at: zipPath)
            let notebookPath = app.testSetupsDirectory + "setup_clc_src.ipynb"
            try starterNotebook.write(toFile: notebookPath, atomically: true, encoding: .utf8)
            let sourceSetup = APITestSetup(
                id: "setup_clc_src", manifest: supportManifest, zipPath: zipPath,
                notebookPath: notebookPath, courseID: courseID)
            try await sourceSetup.save(on: app.db)
            let source = try await makeTestAssignment(
                on: app, testSetupID: "setup_clc_src", courseID: courseID, title: "Lab 1")
            let author = try await makeTestUser(on: app, username: "clc_author", role: "admin")
            let solution = try await makeTestSubmission(
                on: app, id: "sub_clc_soln", setupID: "setup_clc_src",
                userID: try author.requireID(), kind: APISubmission.Kind.validation,
                filename: "solution.ipynb")
            try solutionNotebook.write(toFile: solution.zipPath, atomically: true, encoding: .utf8)
            source.validationSubmissionID = try solution.requireID()
            source.secretRevealEnabled = true
            source.brightspaceSyncExcluded = true
            try await source.save(on: app.db)

            _ = try await postClone(
                courseID,
                form: ["code": "CLC1", "name": "Content Target", "termYear": "2027", "termSeason": "winter"],
                cookie: cookie)

            let clone = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "CLC1").filter(\.$id != courseID).first())
            let cloneID = try clone.requireID()
            #expect(clone.slipDaysEnabled == true)
            #expect(clone.slipDaysPerStudent == 4)
            #expect(clone.slipDayExtensionHours == 36)
            #expect(clone.slipDayReleaseRevealHold == false)

            let cloned = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$courseID == cloneID).first())
            #expect(cloned.secretRevealEnabled == true)
            #expect(cloned.brightspaceSyncExcluded == true)

            // The starter notebook, byte for byte, under the new setup id.
            let clonedSetup = try #require(try await APITestSetup.find(cloned.testSetupID, on: app.db))
            let clonedNotebookPath = try #require(clonedSetup.notebookPath)
            #expect(clonedNotebookPath != notebookPath)
            #expect(try String(contentsOfFile: clonedNotebookPath, encoding: .utf8) == starterNotebook)

            // The reference solution, as a new validation submission with its own file.
            let clonedSolutionID = try #require(cloned.validationSubmissionID)
            #expect(clonedSolutionID != "sub_clc_soln")
            let clonedSolution = try #require(try await APISubmission.find(clonedSolutionID, on: app.db))
            #expect(clonedSolution.kind == APISubmission.Kind.validation)
            #expect(clonedSolution.zipPath != solution.zipPath)
            #expect(try String(contentsOfFile: clonedSolution.zipPath, encoding: .utf8) == solutionNotebook)

            // The shared support directory and the solution source in it.
            let shared = app.testSetupsDirectory + "shared/\(cloned.testSetupID)/"
            #expect(FileManager.default.fileExists(atPath: shared + "data.csv"))
            let solutionSource = try String(contentsOfFile: shared + "solution.py", encoding: .utf8)
            #expect(solutionSource.contains("def answer"))

            // Version 1, with the clone origin.
            let versions = try await APIAssignmentVersion.query(on: app.db)
                .filter(\.$testSetupID == cloned.testSetupID)
                .all()
            #expect(versions.count == 1)
            #expect(versions.first?.origin == AssignmentVersionOrigin.clone)
        }
    }
}
