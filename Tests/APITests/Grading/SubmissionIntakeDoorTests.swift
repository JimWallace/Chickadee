// Tests/APITests/Grading/SubmissionIntakeDoorTests.swift
//
// Every door that creates a student submission goes through
// `SubmissionIntake` (#2768), so every door shows the same effects for the
// same kind of row. Each test sends a real request to one door and checks the
// row and its effects: the owner, the status, the diagnostics a queued job
// records, and Pathfinder. Before #2768 the runner-submit and failover doors
// recorded no diagnostics.
//
// The GitHub door needs a fake GitHub. `GitHubSubmissionIntakeTests` covers it.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3)))
struct SubmissionIntakeDoorTests {

    enum Door: String, CaseIterable, CustomTestStringConvertible {
        case uploadForm, restZip, restFile, browserResult, runnerSubmit, browserFailover

        var testDescription: String { rawValue }

        var gradedInBrowser: Bool { self == .browserResult || self == .browserFailover }

        /// The REST doors are course staff only, and save no user on the row.
        var savesOwner: Bool { self != .restZip && self != .restFile }

        /// A browser result is stored complete. Every other row waits for a runner.
        var status: SubmissionStatus { self == .browserResult ? .complete : .pending }
    }

    private struct Fixture {
        let setupID: String
        let userID: UUID
        let cookie: String
        let csrf: String
    }

    private func fixture(_ app: Application, door: Door) async throws -> Fixture {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let setupID = "intake_\(door.rawValue)"
        try await makeTestSetup(
            on: app, id: setupID, courseID: courseID,
            manifest: door.gradedInBrowser ? TestManifests.browserEmpty : TestManifests.workerOnePythonSuite)
        try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
        let username = "intake_\(door.rawValue)_user"
        let cookie = try await loginAsStudent(username, on: app)
        try await enrollInTestCourse(
            username: username, role: door.savesOwner ? .student : .instructor, on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        let (csrf, sessionCookie) = try await csrfFields(
            for: door == .uploadForm ? "/testsetups/\(setupID)/submit" : "/login", cookie: cookie, on: app)
        return Fixture(setupID: setupID, userID: try user.requireID(), cookie: sessionCookie, csrf: csrf)
    }

    private static let notebookJSON =
        #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","source":["x = 1"],"metadata":{},"outputs":[]}]}"#

    private static func collection(setupID: String) -> String {
        """
        {"submissionID":"","testSetupID":"\(setupID)","attemptNumber":1,"buildStatus":"passed",
         "compilerOutput":null,"outcomes":[{"testName":"t","testClass":null,"tier":"public",
         "status":"pass","shortResult":"passed","longResult":null,"executionTimeMs":5,
         "memoryUsageBytes":null,"attemptNumber":1,"isFirstPassSuccess":true}],
         "totalTests":1,"passCount":1,"failCount":0,"errorCount":0,"timeoutCount":0,
         "executionTimeMs":5,"runnerVersion":"browser-wasm-runner/1.0","timestamp":"2026-01-01T00:00:00Z"}
        """
    }

    private func send(_ door: Door, _ fx: Fixture, on app: Application) async throws -> HTTPStatus {
        let path: String =
            switch door {
            case .uploadForm: "/testsetups/\(fx.setupID)/submit"
            case .restZip: "/api/v1/submissions"
            case .restFile: "/api/v1/submissions/file"
            case .browserResult: "/api/v1/submissions/browser-result"
            case .runnerSubmit: "/api/v1/submissions/runner-submit"
            case .browserFailover: "/api/v1/submissions/browser-failover"
            }
        let notebook = Data(Self.notebookJSON.utf8)
        var status: HTTPStatus = .internalServerError
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: fx.cookie)
                req.headers.add(name: "x-csrf-token", value: fx.csrf)
                switch door {
                case .uploadForm:
                    let boundary = "Boundary-\(UUID().uuidString)"
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                    req.body = wrSubmitMultipartBody(boundary: boundary, csrfToken: fx.csrf)
                case .restZip:
                    try req.content.encode(
                        CreateSubmissionBody(
                            testSetupID: fx.setupID, zipBase64: Data("PK\u{03}\u{04}zip".utf8).base64EncodedString()),
                        as: .json)
                case .restFile:
                    try req.content.encode(
                        SubmitFileBody(testSetupID: fx.setupID, filename: "work.ipynb", file: notebook), as: .json)
                case .browserResult:
                    try req.content.encode(
                        BrowserResultBody(
                            collection: Self.collection(setupID: fx.setupID), notebook: notebook,
                            testSetupID: fx.setupID),
                        as: .json)
                case .runnerSubmit:
                    try req.content.encode(
                        RunnerSubmitBody(notebook: notebook, testSetupID: fx.setupID, filename: "work.ipynb"),
                        as: .json)
                case .browserFailover:
                    try req.content.encode(
                        BrowserFailoverBody(testSetupID: fx.setupID, notebook: Self.notebookJSON), as: .json)
                }
            },
            afterResponse: { res in status = res.status })
        return status
    }

    @Test(arguments: Door.allCases)
    func everyDoorRunsTheSharedEffects(door: Door) async throws {
        try await withTestApp(prefix: "chickadee-intake-doors") { app in
            let fx = try await fixture(app, door: door)
            let status = try await send(door, fx, on: app)
            #expect(status == (door == .uploadForm ? .seeOther : .ok))

            let rows = try await APISubmission.query(on: app.db).filter(\.$testSetupID == fx.setupID).all()
            let row = try #require(rows.first)
            #expect(rows.count == 1)
            let subID = try row.requireID()
            #expect(row.kind == APISubmission.Kind.student)
            #expect(row.attemptNumber == 1)
            #expect(row.status == door.status.rawValue)
            #expect(row.userID == (door.savesOwner ? fx.userID : nil))
            #expect(FileManager.default.fileExists(atPath: row.zipPath))

            // A queued job records "accepted" and "enqueued". A browser result
            // queues no job.
            let diagnostics = try await APISubmissionDiagnostics.find(subID, on: app.db)
            let metric = try await JobExecutionMetric.query(on: app.db)
                .filter(\.$submissionID == subID).first()
            #expect((diagnostics != nil) == (door.status == .pending))
            #expect((metric != nil) == (door.status == .pending))

            // Pathfinder goes to the first student who submits, on every door
            // that knows who the student is.
            let pathfinder = try await APIClassAchievement.query(on: app.db)
                .filter(\.$testSetupID == fx.setupID)
                .filter(\.$achievementID == "pathfinder")
                .first()
            #expect(pathfinder?.userID == (door.savesOwner ? fx.userID : nil))
        }
    }

    /// Every door that takes a notebook stores it merged with the instructor
    /// notebook, through one helper.
    @Test(arguments: [Door.restFile, .runnerSubmit, .browserFailover, .browserResult])
    func aNotebookDoorStoresTheMergedNotebook(door: Door) async throws {
        try await withTestApp(prefix: "chickadee-intake-doors") { app in
            let fx = try await fixture(app, door: door)
            _ = try await send(door, fx, on: app)
            let row = try #require(
                try await APISubmission.query(on: app.db).filter(\.$testSetupID == fx.setupID).first())
            let setup = try #require(try await APITestSetup.find(fx.setupID, on: app.db))
            let instructor = try await app.notebookBytesCache.notebookData(for: NotebookSourceRef(setup))
            let expected = mergeNotebook(student: Data(Self.notebookJSON.utf8), instructor: instructor)
            #expect(try Data(contentsOf: URL(fileURLWithPath: row.zipPath)) == expected)
        }
    }
}
