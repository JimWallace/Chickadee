// Tests/APITests/Fixtures.swift
//
// Centralized fixture builders for `APICourse`, `APIUser`, `APITestSetup`,
// `APIAssignment`, `APICourseEnrollment`, `APISubmission`, `APIResult`.
//
// Before this file, 6+ suites (AdminRoutesTests, AccountRoutesTests,
// AssignmentEnrollmentTests, AssignmentSeedStoreTests,
// EnrollmentRoutesTests, NotebookWebRoutesTests, …) each defined their
// own `private func makeCourse`/`makeUser`/`makeSetup` wrappers — same
// shape, slightly different defaults.  Each one was ~10 LOC.  When the
// underlying model gained a field, every copy needed to be updated.
//
// `TestScenario` at the end builds the course, setup and assignment that
// most suites start from, and enrolls users in it.
//
// These are free functions (not methods on a test suite type) so they
// work from both struct-based and class-based suites, and require no
// inheritance.  Per-suite specializations can still be added at call
// sites where defaults are unusual — the centralized helpers only cover
// the canonical "give me a saved row I can use" path.

import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer
@testable import Core

// MARK: - Course

@discardableResult
func makeTestCourse(
    on app: Application,
    code: String = "TEST101",
    name: String? = nil,
    archived: Bool = false,
    mode: CourseEnrollmentMode = .open
) async throws -> APICourse {
    let course = APICourse(
        code: code,
        name: name ?? "Course \(code)",
        isArchived: archived,
        enrollmentMode: mode
    )
    try await course.save(on: app.db)
    return course
}

// MARK: - User / Student

@discardableResult
func makeTestUser(
    on app: Application,
    username: String,
    role: String = "student",
    passwordHash: String? = nil
) async throws -> APIUser {
    let user = APIUser(
        username: username,
        passwordHash: try passwordHash ?? testPasswordHash("pw"),
        role: role
    )
    try await user.save(on: app.db)
    return user
}

/// Convenience wrapper — same as `makeTestUser` with `role: "student"`.
@discardableResult
func makeTestStudent(on app: Application, username: String) async throws -> APIUser {
    try await makeTestUser(on: app, username: username, role: "student")
}

// MARK: - Enrollment

@discardableResult
func makeTestEnrollment(
    on app: Application,
    userID: UUID,
    courseID: UUID
) async throws -> APICourseEnrollment {
    // Seed the per-course role from the user's global role (mirroring production
    // saveSeededEnrollment) so a global instructor/admin enrolled for testing
    // becomes course staff — otherwise the per-course roster counts and staff
    // gates (#417 Slice G) would treat them as an ordinary student. The global
    // `instructor` role no longer exists as a UserRole case (#417 Slice G2), so
    // legacy `"instructor"` role strings (still used by test logins) and admins
    // seed to a per-course instructor, matching the migration backfill.
    let user = try await APIUser.find(userID, on: app.db)
    let isInstructor = (user?.role == "instructor") || (user?.isAdmin ?? false)
    let enrollment = APICourseEnrollment(
        userID: userID, courseID: courseID, role: isInstructor ? .instructor : .student)
    try await enrollment.save(on: app.db)
    return enrollment
}

// MARK: - Test setup

private let minimalEmptyZipBytes: [UInt8] =
    [0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)

private let minimalEmptyNotebookJSON =
    #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#

private let minimalBrowserGradingModeManifest = """
    {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
    """

@discardableResult
func makeTestSetup(
    on app: Application,
    id: String,
    courseID: UUID,
    manifest: String = minimalBrowserGradingModeManifest,
    withNotebook: Bool = true,
    withZip: Bool = true
) async throws -> APITestSetup {
    let zipPath = app.testSetupsDirectory + "\(id).zip"
    let notebookPath = app.testSetupsDirectory + "\(id).ipynb"
    if withZip {
        try Data(minimalEmptyZipBytes).write(to: URL(fileURLWithPath: zipPath))
    }
    if withNotebook {
        try minimalEmptyNotebookJSON
            .write(to: URL(fileURLWithPath: notebookPath), atomically: true, encoding: .utf8)
    }
    let setup = APITestSetup(
        id: id,
        manifest: manifest,
        zipPath: zipPath,
        notebookPath: withNotebook ? notebookPath : nil,
        courseID: courseID
    )
    try await setup.save(on: app.db)
    return setup
}

// MARK: - Assignment

@discardableResult
func makeTestAssignment(
    on app: Application,
    testSetupID: String,
    courseID: UUID,
    title: String = "Test Lab",
    dueAt: Date? = nil,
    isOpen: Bool = true
) async throws -> APIAssignment {
    let assignment = APIAssignment(
        testSetupID: testSetupID,
        title: title,
        dueAt: dueAt,
        isOpen: isOpen,
        courseID: courseID
    )
    try await assignment.save(on: app.db)
    return assignment
}

// MARK: - Submission

@discardableResult
func makeTestSubmission(
    on app: Application,
    id: String,
    setupID: String,
    userID: UUID,
    kind: String = APISubmission.Kind.student,
    status: String = "complete",
    filename: String? = nil
) async throws -> APISubmission {
    let path = app.submissionsDirectory + "\(id).ipynb"
    try minimalEmptyNotebookJSON
        .write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    let submission = APISubmission(
        id: id,
        testSetupID: setupID,
        zipPath: path,
        attemptNumber: 1,
        status: status,
        filename: filename ?? "\(id).ipynb",
        userID: userID,
        kind: kind
    )
    try await submission.save(on: app.db)
    return submission
}

// MARK: - Result

@discardableResult
func makeTestResult(
    on app: Application,
    submissionID: String,
    collectionJSON: String? = nil,
    source: String = "worker"
) async throws -> APIResult {
    let result = APIResult(
        id: "res_\(UUID().uuidString.lowercased().prefix(8))",
        submissionID: submissionID,
        source: source
    )
    try await result.saveWithCollection(
        json: collectionJSON ?? #"{"submissionID":"\#(submissionID)","outcomes":[]}"#,
        on: app.db)
    return result
}

// MARK: - Scenario

/// A saved course with one test setup and its assignment: the rows that most
/// suites build before their first request. Use it instead of a local
/// `fixture()` that calls `makeTestCourse`, `makeTestSetup` and
/// `makeTestAssignment` in turn.
struct TestScenario {
    let course: APICourse
    let courseID: UUID
    let setup: APITestSetup
    let setupID: String
    let assignment: APIAssignment
    let assignmentID: UUID

    /// Saves the course, the setup and the assignment, with the defaults of
    /// `makeTestCourse`, `makeTestSetup` and `makeTestAssignment`.
    static func make(
        on app: Application,
        code: String = "TEST101",
        courseName: String? = nil,
        mode: CourseEnrollmentMode = .open,
        setupID: String,
        manifest: String = minimalBrowserGradingModeManifest,
        withNotebook: Bool = true,
        withZip: Bool = true,
        title: String = "Test Lab",
        dueAt: Date? = nil,
        isOpen: Bool = true
    ) async throws -> TestScenario {
        let course = try await makeTestCourse(on: app, code: code, name: courseName, mode: mode)
        let courseID = try course.requireID()
        let setup = try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: manifest, withNotebook: withNotebook,
            withZip: withZip)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: title, dueAt: dueAt, isOpen: isOpen)
        return TestScenario(
            course: course, courseID: courseID, setup: setup, setupID: setupID, assignment: assignment,
            assignmentID: try assignment.requireID())
    }

    /// The same, with the manifest encoded from `properties`.
    static func make(
        on app: Application,
        code: String = "TEST101",
        courseName: String? = nil,
        mode: CourseEnrollmentMode = .open,
        setupID: String,
        properties: TestProperties,
        withNotebook: Bool = true,
        withZip: Bool = true,
        title: String = "Test Lab",
        dueAt: Date? = nil,
        isOpen: Bool = true
    ) async throws -> TestScenario {
        let manifest = try #require(String(data: JSONEncoder().encode(properties), encoding: .utf8))
        return try await make(
            on: app, code: code, courseName: courseName, mode: mode, setupID: setupID, manifest: manifest,
            withNotebook: withNotebook, withZip: withZip, title: title, dueAt: dueAt, isOpen: isOpen)
    }

    /// Saves a user with `role` and enrolls them in the course. Returns the
    /// user ID.
    @discardableResult
    func enroll(_ username: String, role: String = "student", on app: Application) async throws -> UUID {
        let id = try await makeTestUser(on: app, username: username, role: role).requireID()
        try await makeTestEnrollment(on: app, userID: id, courseID: courseID)
        return id
    }
}
