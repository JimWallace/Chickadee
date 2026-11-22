// Tests/APITests/WebRoutesHelpers.swift
//
// Free-function versions of the helpers previously hosted on
// WebRoutesTestCase.  Swift Testing class suites don't subclass
// XCTestCase, so the shared base-class pattern is replaced with
// `app`-taking helpers that any suite can call.
//
// A test wraps its body in `try await withTestApp { app in ... }`.
// See `WebRoutesSubmitHistoryTests` for the consumer pattern.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

// MARK: - Auth helpers

func wrLoginAsStudent(on app: Application) async throws -> String {
    try await loginUser(username: "student1", password: "pass", role: "student", on: app)
}

func wrLoginAsInstructor(on app: Application) async throws -> String {
    try await loginUser(username: "instructor1", password: "pass", role: "instructor", on: app)
}

// MARK: - Seeding helpers

func wrStudentUser(on app: Application) async throws -> APIUser {
    try #require(try await APIUser.query(on: app.db).filter(\.$username == "student1").first())
}

func wrMakeCourse(on app: Application) async throws -> APICourse {
    if let existing = try await APICourse.query(on: app.db).filter(\.$code == "CS101").first() {
        return existing
    }
    let course = APICourse(code: "CS101", name: "Intro CS")
    try await course.save(on: app.db)
    return course
}

func wrEnrollUser(_ user: APIUser, on app: Application) async throws {
    let course = try await wrMakeCourse(on: app)
    let courseID = try course.requireID()
    let userID = try user.requireID()
    if try await APICourseEnrollment.query(on: app.db)
        .filter(\.$userID == userID)
        .filter(\.$course.$id == courseID)
        .first() == nil
    {
        // Seed the per-course role from the global role, mirroring production
        // (saveSeededEnrollment), so a global-instructor caller becomes a
        // per-course instructor — Phase 5 made instructor authority per-course.
        // The global `instructor` UserRole case is gone (#417 Slice G2); a
        // legacy `"instructor"` role string or an admin seeds to instructor.
        let isStaff = (user.role == "instructor") || user.isAdmin
        let role: CourseRole = isStaff ? .instructor : .student
        let enrollment = APICourseEnrollment(userID: userID, courseID: courseID, role: role)
        try await enrollment.save(on: app.db)
    }
}

@discardableResult
func wrInsertSetup(
    id: String,
    manifest: String? = nil,
    on app: Application
) async throws -> APITestSetup {
    let manifestJSON =
        manifest
            ?? """
            {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
            """
    let courseID = try await wrMakeCourse(on: app).requireID()
    return try await makeTestSetup(
        on: app, id: id, courseID: courseID, manifest: manifestJSON, withNotebook: false, withZip: false)
}

/// A manifest with one public and one secret suite entry — the seed for
/// secret-reveal-token tests (`wrInsertSetup(id:manifest:)`).
let wrManifestWithSecretTier = """
    {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"},{"tier":"secret","script":"secrettest.sh"}],"timeLimitSeconds":10}
    """

@discardableResult
func wrInsertAssignment(
    testSetupID: String,
    title: String,
    isOpen: Bool,
    dueAt: Date? = nil,
    secretRevealEnabled: Bool = false,
    on app: Application
) async throws -> APIAssignment {
    let course = try await wrMakeCourse(on: app)
    let courseID = try course.requireID()
    let a = APIAssignment(
        testSetupID: testSetupID, title: title, dueAt: dueAt, visibility: isOpen ? .open : .closed, courseID: courseID)
    if secretRevealEnabled {
        a.secretRevealEnabled = true
    }
    try await a.save(on: app.db)
    return a
}

@discardableResult
func wrInsertSubmission(
    id: String,
    testSetupID: String,
    userID: UUID,
    attemptNumber: Int = 1,
    status: String = "complete",
    filename: String? = nil,
    on app: Application
) async throws -> APISubmission {
    let sub = APISubmission(
        id: id,
        testSetupID: testSetupID,
        zipPath: app.submissionsDirectory + "\(id).py",
        attemptNumber: attemptNumber,
        status: status,
        filename: filename,
        userID: userID,
        kind: APISubmission.Kind.student
    )
    try await sub.save(on: app.db)
    return sub
}

func wrMakeOutcome(
    name: String,
    tier: TestTier = .pub,
    status: TestStatus = .pass,
    shortResult: String? = nil,
    longResult: String? = nil
) -> TestOutcome {
    TestOutcome(
        testName: name,
        testClass: nil,
        tier: tier,
        status: status,
        shortResult: shortResult ?? (status == .pass ? "passed" : "failed"),
        longResult: status == .pass ? longResult : (longResult ?? "test output here"),
        executionTimeMs: 10,
        memoryUsageBytes: nil,
        attemptNumber: 1,
        isFirstPassSuccess: status == .pass
    )
}

func wrMakeCollection(
    submissionID: String,
    outcomes: [TestOutcome] = [],
    warnings: [String] = []
) -> TestOutcomeCollection {
    TestOutcomeCollection(
        submissionID: submissionID,
        testSetupID: "setup_001",
        attemptNumber: 1,
        buildStatus: .passed,
        compilerOutput: nil,
        outcomes: outcomes,
        totalTests: outcomes.count,
        passCount: outcomes.filter { $0.status == .pass }.count,
        failCount: outcomes.filter { $0.status == .fail }.count,
        errorCount: outcomes.filter { $0.status == .error }.count,
        timeoutCount: outcomes.filter { $0.status == .timeout }.count,
        executionTimeMs: 100,
        warnings: warnings,
        runnerVersion: "shell-runner/1.0",
        timestamp: Date(timeIntervalSince1970: 0)
    )
}

@discardableResult
func wrInsertResult(
    submissionID: String,
    outcomes: [TestOutcome] = [],
    warnings: [String] = [],
    source: String = "worker",
    on app: Application
) async throws -> APIResult {
    let collection = wrMakeCollection(submissionID: submissionID, outcomes: outcomes, warnings: warnings)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let json = try String(data: encoder.encode(collection), encoding: .utf8) ?? ""
    let result = APIResult(
        id: "res_\(UUID().uuidString.lowercased().prefix(8))",
        submissionID: submissionID,
        source: source
    )
    try await result.saveWithCollection(json: json, on: app.db)
    return result
}

/// The body of the standard one-file upload form: the `_csrf` field and one
/// `submission.py` part named `files`.
func wrSubmitMultipartBody(boundary: String, csrfToken: String) -> ByteBuffer {
    arMultipartBody(
        boundary: boundary,
        fields: [("_csrf", csrfToken)],
        files: [("files", "submission.py", "text/x-python", Data("print('hello')\n".utf8))])
}

/// POSTs the standard one-file upload (`wrSubmitMultipartBody`) to
/// `/testsetups/:id/submit` in the session `sessionCookie`, and returns the
/// response.
func wrPostSubmitUpload(
    setupID: String, csrfToken: String, sessionCookie: String, on app: Application
) async throws -> TestResponse {
    let boundary = "submit-upload-boundary"
    return try await app.asyncSendRequest(.POST, "/testsetups/\(setupID)/submit") { req in
        req.headers.add(name: .cookie, value: sessionCookie)
        req.headers.contentType = HTTPMediaType(
            type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
        req.body = wrSubmitMultipartBody(boundary: boundary, csrfToken: csrfToken)
    }
}

/// Submit one file as `username` (creating the user with `role` if
/// it doesn't exist, enrolling them, and POSTing through the same
/// `/testsetups/:id/submit` path students use).
func wrSubmitOnceAs(
    username: String,
    role: String,
    setupID: String,
    on app: Application
) async throws {
    let cookie = try await loginUser(
        username: username, password: "pass", role: role, on: app
    )
    let user = try #require(
        try await APIUser.query(on: app.db).filter(\.$username == username).first(),
        "Could not find user \(username) after loginUser"
    )
    try await wrEnrollUser(user, on: app)
    let (csrf, sessionCookie) = try await csrfFields(
        for: "/testsetups/\(setupID)/submit", cookie: cookie, on: app
    )
    let res = try await wrPostSubmitUpload(
        setupID: setupID, csrfToken: csrf, sessionCookie: sessionCookie, on: app)
    #expect(res.status == .seeOther, "Submit should redirect on success (got \(res.status))")
}
