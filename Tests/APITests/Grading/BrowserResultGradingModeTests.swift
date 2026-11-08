// Tests/APITests/Grading/BrowserResultGradingModeTests.swift
//
// A browser result is computed in the student's own browser, so the student
// can forge it. `POST /api/v1/submissions/browser-result` must refuse one for a
// worker-graded assignment, or an enrolled student could store any grade for
// an assignment that is meant to be graded on a native runner only
// (docs/grading-integrity.md D8).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3)))
struct BrowserResultGradingModeTests {

    private static let notebookJSON =
        #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#

    private static func forgedCollection(setupID: String) -> String {
        """
        {"submissionID":"","testSetupID":"\(setupID)","attemptNumber":1,"buildStatus":"passed",
         "compilerOutput":null,"outcomes":[{"testName":"t","testClass":null,"tier":"public",
         "status":"pass","shortResult":"passed","longResult":null,"executionTimeMs":5,
         "memoryUsageBytes":null,"attemptNumber":1,"isFirstPassSuccess":true}],
         "totalTests":1,"passCount":1,"failCount":0,"errorCount":0,"timeoutCount":0,
         "executionTimeMs":5,"runnerVersion":"browser-wasm-runner/1.0","timestamp":"2026-01-01T00:00:00Z"}
        """
    }

    @Test(arguments: [
        (TestManifests.workerOnePythonSuite, HTTPStatus.badRequest, 0),
        (TestManifests.browserEmpty, HTTPStatus.ok, 1),
    ])
    func browserResultIsAcceptedOnlyForBrowserGradedAssignments(
        manifest: String, expected: HTTPStatus, rowCount: Int
    ) async throws {
        try await withTestApp(prefix: "chickadee-browser-result-mode") { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setupID = "brmode_\(expected.code)"
            try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: manifest)
            try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
            let username = "brmode_\(expected.code)_user"
            let cookie = try await loginAsStudent(username, on: app)
            try await enrollInTestCourse(username: username, role: .student, on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

            var status: HTTPStatus = .internalServerError
            try await app.asyncTest(
                .POST, "/api/v1/submissions/browser-result",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    try req.content.encode(
                        BrowserResultBody(
                            collection: Self.forgedCollection(setupID: setupID),
                            notebook: Data(Self.notebookJSON.utf8), testSetupID: setupID),
                        as: .json)
                },
                afterResponse: { res in status = res.status })

            #expect(status == expected)
            let rows = try await APISubmission.query(on: app.db).filter(\.$testSetupID == setupID).count()
            #expect(rows == rowCount)
        }
    }
}
