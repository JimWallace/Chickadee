// Tests/APITests/Admin/AdminRouteFixtures.swift
//
// The helpers that the admin route suites share: AdminRoutesTests,
// AdminUserDeleteCleanupTests, AdminCourseManagementRoutesTests and
// AdminRunnersRoutesTests. Each suite is a class with a stored `app`, and
// conforming to `AdminRouteFixtures` gives it these helpers.

import Core
import Foundation
import VaporTesting

@testable import APIServer

/// An admin route suite: a class suite with a stored test `app`.
protocol AdminRouteFixtures: AnyObject {
    var app: Application { get }
}

extension AdminRouteFixtures {

    func csrfCookieAndToken(_ cookie: String, path: String = "/admin") async throws -> (String, String) {
        let (token, boundCookie) = try await csrfFields(for: path, cookie: cookie, on: app)
        return (boundCookie, token)
    }

    // Suite-specific defaults that wrap the centralized fixture
    // builders in Tests/APITests/Fixtures.swift.  Kept as wrappers
    // (not call-site `makeTestCourse(on: app, ...)`) so the many call
    // sites in the admin suites don't churn.

    @discardableResult
    func makeCourse(
        code: String = "ADM101",
        name: String = "Admin Test Course",
        archived: Bool = false,
        mode: CourseEnrollmentMode = .open
    ) async throws -> APICourse {
        try await makeTestCourse(on: app, code: code, name: name, archived: archived, mode: mode)
    }

    @discardableResult
    func makeUser(username: String, role: String = "student") async throws -> APIUser {
        try await makeTestUser(on: app, username: username, role: role)
    }

    @discardableResult
    func makeSetup(
        id: String,
        courseID: UUID,
        withNotebook: Bool = true
    ) async throws -> APITestSetup {
        try await makeTestSetup(on: app, id: id, courseID: courseID, withNotebook: withNotebook)
    }

    @discardableResult
    func makeAssignment(
        testSetupID: String,
        courseID: UUID,
        title: String = "Admin Lab"
    ) async throws -> APIAssignment {
        try await makeTestAssignment(on: app, testSetupID: testSetupID, courseID: courseID, title: title)
    }

    @discardableResult
    func makeEnrollment(userID: UUID, courseID: UUID) async throws -> APICourseEnrollment {
        try await makeTestEnrollment(on: app, userID: userID, courseID: courseID)
    }

    @discardableResult
    func makeSubmission(
        id: String,
        setupID: String,
        userID: UUID
    ) async throws -> APISubmission {
        try await makeTestSubmission(on: app, id: id, setupID: setupID, userID: userID)
    }

    @discardableResult
    func makeResult(submissionID: String) async throws -> APIResult {
        try await makeTestResult(on: app, submissionID: submissionID)
    }
}
