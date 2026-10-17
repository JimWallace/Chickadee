// Tests/APITests/ActivityWindowSubmissionDoorTests.swift
//
// Every door that hands work in must refuse a student outside a class
// activity's live-session window (docs/class-activities.md).
//
// `ActivitySessionWindowTests` pins the gate itself by calling
// `requireOpenStudentAssignment` directly. That cannot see a door that calls
// the gate with `.access` instead of `.submission`: such a door still refuses a
// closed assignment, so a closed-assignment test passes, but it skips the
// window. These tests send a real request to each submission door.
//
// The GitHub submit door is not here. It reaches the gate only after it finds
// a linked account and a repository template, and its own suite covers it.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3)))
struct ActivityWindowSubmissionDoorTests {

    // MARK: - Fixture

    private struct Fixture {
        let setupID: String
        let cookie: String
        let csrf: String
    }

    /// An open, worker-graded assignment whose class activity runs to
    /// `window`, and a signed-in student enrolled in its course.
    private func fixture(
        _ app: Application, prefix: String, window: LiveSessionWindow, asInstructor: Bool = false
    ) async throws -> Fixture {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let setupID = "\(prefix)_setup"
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            language: nil,
            activity: ClassActivity(
                kind: .bestMetric, leaderboardVisibility: .visible, opponentFile: nil, window: window))
        let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
        try await APITestSetup(
            id: setupID, manifest: manifest,
            zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: courseID
        ).save(on: app.db)
        _ = try await arInsertAssignment(testSetupID: setupID, title: "Contest \(prefix)", isOpen: true, on: app)

        let username = "\(prefix)_user"
        let cookie = try await loginAsStudent(username, on: app)
        if asInstructor {
            try await enrollInTestCourse(username: username, role: .instructor, on: app)
        }
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
        return Fixture(setupID: setupID, cookie: sessionCookie, csrf: csrf)
    }

    private static let closedWindow = LiveSessionWindow(
        opensAt: nil, closesAt: Date().addingTimeInterval(-60))
    private static let pendingWindow = LiveSessionWindow(
        opensAt: Date().addingTimeInterval(3_600), closesAt: nil)

    private func submissionCount(_ app: Application, _ setupID: String) async throws -> Int {
        try await APISubmission.query(on: app.db).filter(\.$testSetupID == setupID).count()
    }

    // MARK: - The JSON doors

    /// The three JSON doors share one body shape for this purpose: they decode
    /// the body, check enrollment, then run the gate.
    enum JSONDoor: String, CaseIterable, CustomTestStringConvertible {
        case browserResult = "browser-result"
        case runnerSubmit = "runner-submit"
        case browserFailover = "browser-failover"

        var testDescription: String { rawValue }

        /// What the door answers a staff request once the window gate has let
        /// it through: the next check that the stub body meets.
        var statusPastTheGate: HTTPStatus {
            switch self {
            case .browserResult: .unprocessableEntity
            case .runnerSubmit: .ok
            case .browserFailover: .badRequest
            }
        }

        var textPastTheGate: String {
            switch self {
            case .browserResult: "Invalid TestOutcomeCollection"
            case .runnerSubmit: "submissionID"
            case .browserFailover: "only for browser-graded assignments"
            }
        }

        func encode(setupID: String, into req: inout TestRequest) throws {
            let notebookJSON = #"{"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}"#
            let notebook = Data(notebookJSON.utf8)
            switch self {
            case .browserResult:
                try req.content.encode(
                    BrowserResultBody(collection: "{}", notebook: notebook, testSetupID: setupID), as: .json)
            case .runnerSubmit:
                try req.content.encode(
                    RunnerSubmitBody(notebook: notebook, testSetupID: setupID, filename: nil), as: .json)
            case .browserFailover:
                try req.content.encode(
                    BrowserFailoverBody(
                        testSetupID: setupID, notebook: notebookJSON),
                    as: .json)
            }
        }
    }

    private func post(
        _ door: JSONDoor, _ fx: Fixture, on app: Application
    ) async throws -> (status: HTTPStatus, body: String) {
        var status: HTTPStatus = .ok
        var body = ""
        try await app.asyncTest(
            .POST, "/api/v1/submissions/\(door.rawValue)",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: fx.cookie)
                req.headers.add(name: "x-csrf-token", value: fx.csrf)
                try door.encode(setupID: fx.setupID, into: &req)
            },
            afterResponse: { res in
                status = res.status
                body = res.body.string
            })
        return (status, body)
    }

    @Test(arguments: JSONDoor.allCases)
    func aJSONDoorRefusesAStudentAfterTheSessionCloses(door: JSONDoor) async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "after_\(door)", window: Self.closedWindow)

            let response = try await post(door, fx, on: app)

            #expect(response.status == .forbidden)
            #expect(response.body.contains("class activity closed at"))
            #expect(try await submissionCount(app, fx.setupID) == 0)
        }
    }

    @Test(arguments: JSONDoor.allCases)
    func aJSONDoorRefusesAStudentBeforeTheSessionOpens(door: JSONDoor) async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "before_\(door)", window: Self.pendingWindow)

            let response = try await post(door, fx, on: app)

            #expect(response.status == .forbidden)
            #expect(response.body.contains("class activity opens at"))
            #expect(try await submissionCount(app, fx.setupID) == 0)
        }
    }

    @Test(arguments: JSONDoor.allCases)
    func aJSONDoorLetsCourseStaffInAfterTheSessionCloses(door: JSONDoor) async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(
                app, prefix: "staff_\(door)", window: Self.closedWindow, asInstructor: true)

            let response = try await post(door, fx, on: app)

            // Past the gate, each door reaches its own next check with the
            // stub body. Reaching that check is what proves the gate let them in.
            #expect(response.status == door.statusPastTheGate, "staff are never gated by the window")
            #expect(response.body.contains(door.textPastTheGate))
        }
    }

    // MARK: - The form doors

    @Test(arguments: [
        ("after", Self.closedWindow, "class activity closed at"),
        ("before", Self.pendingWindow, "class activity opens at"),
    ])
    func theUploadFormRefusesAStudentOutsideTheSession(
        side: String, window: LiveSessionWindow, reason: String
    ) async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "upload_\(side)", window: window)
            let path = "/testsetups/\(fx.setupID)/submit"
            let (token, cookie) = try await csrfFields(for: path, cookie: fx.cookie, on: app)
            let boundary = "Boundary-\(UUID().uuidString)"

            var status: HTTPStatus = .ok
            var body = ""
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                    req.body = wrSubmitMultipartBody(boundary: boundary, csrfToken: token)
                },
                afterResponse: { res in
                    status = res.status
                    body = res.body.string
                })

            #expect(status == .forbidden)
            #expect(body.contains(reason), "the refusal is the window, not another 403")
            #expect(try await submissionCount(app, fx.setupID) == 0)
        }
    }

    @Test(arguments: [("after", Self.closedWindow), ("before", Self.pendingWindow)])
    func theFillAHoleFormRefusesAStudentOutsideTheSession(side: String, window: LiveSessionWindow) async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "spare_\(side)", window: window)
            let path = "/testsetups/\(fx.setupID)/composite/spare"

            var location: String?
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: fx.cookie)
                    try req.content.encode(["_csrf": fx.csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in location = res.headers.first(name: .location) })

            #expect(location?.contains("spare=\(SpareFlash.closed.rawValue)") == true)
            #expect(try await submissionCount(app, fx.setupID) == 0)
        }
    }
}
