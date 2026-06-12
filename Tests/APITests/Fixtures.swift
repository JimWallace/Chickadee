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
// These are free functions (not methods on a test suite type) so they
// work from both struct-based and class-based suites, and require no
// inheritance.  Per-suite specializations can still be added at call
// sites where defaults are unusual — the centralized helpers only cover
// the canonical "give me a saved row I can use" path.

import Fluent
import Foundation
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
    let enrollment = APICourseEnrollment(userID: userID, courseID: courseID)
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
    withNotebook: Bool = true
) async throws -> APITestSetup {
    let zipPath = app.testSetupsDirectory + "\(id).zip"
    let notebookPath = app.testSetupsDirectory + "\(id).ipynb"
    try Data(minimalEmptyZipBytes).write(to: URL(fileURLWithPath: zipPath))
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
        collectionJSON: collectionJSON ?? #"{"submissionID":"\#(submissionID)","outcomes":[]}"#,
        source: source
    )
    try await result.save(on: app.db)
    return result
}
