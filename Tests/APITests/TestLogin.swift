// Tests/APITests/TestLogin.swift
//
// Test users, their sign-in, and the shared test course: the fixtures a
// test needs before it can request a page as somebody.

import Core
import Fluent
import Foundation
import VaporTesting

@testable import APIServer

// MARK: - Course fixture helper

private struct TestCourseIDsKey: StorageKey {
    typealias Value = [String: UUID]
}

extension Application {
    /// Returns the UUID of a test `APICourse` with `code`, creating it on first
    /// call.  Memoized per `Application` in `storage` so repeat callers don't
    /// re-query the database.  Six test classes previously each carried a
    /// private copy of this helper; consolidating here matches the same
    /// drift-avoidance rationale as `makeTestApp` / `registerMigrations`.
    func testCourseID(
        code: String = "TEST101",
        name: String = "Test Course",
        enrollmentMode: CourseEnrollmentMode = .open
    ) async throws -> UUID {
        if let cached = storage[TestCourseIDsKey.self]?[code] {
            return cached
        }
        let course: APICourse
        if let existing = try await APICourse.query(on: db).filter(\.$code == code).first() {
            course = existing
        } else {
            course = APICourse(code: code, name: name, enrollmentMode: enrollmentMode)
            try await course.save(on: db)
        }
        let id = try course.requireID()
        var cache = storage[TestCourseIDsKey.self] ?? [:]
        cache[code] = id
        storage[TestCourseIDsKey.self] = cache
        return id
    }
}

/// Enrols `username` as a per-course instructor in the shared TEST101 course so
/// the per-course `/instructor` gate (Phase 5) admits them. Idempotent.
func enrollAsTestInstructor(
    username: String, on app: Application, courseCode: String = "TEST101"
) async throws {
    let courseID = try await app.testCourseID(code: courseCode)
    guard let user = try await APIUser.query(on: app.db).filter(\.$username == username).first()
    else { return }
    let userID = try user.requireID()
    // Upsert to `.instructor` — a `.auto` course auto-enrolls the user at login
    // and (post role-collapse, #417 Slice G2) seeds a non-admin as a per-course
    // `.student`, so skipping on "already enrolled" could leave them a student
    // and 403 the per-course staff gates.
    if let existing = try await APICourseEnrollment.query(on: app.db)
        .filter(\.$userID == userID).filter(\.$course.$id == courseID).first()
    {
        if existing.role != .instructor {
            existing.role = .instructor
            try await existing.save(on: app.db)
        }
    } else {
        try await APICourseEnrollment(userID: userID, courseID: courseID, role: .instructor)
            .save(on: app.db)
    }
}

/// Demotes every one of `username`'s course enrollments to `.student` — the
/// per-course equivalent of the retired "downgrade the global role" move (#417
/// Slice G2 collapsed the deployment role to user/admin/mcp, so teaching
/// authority lives on the enrollment). After this the user is staff nowhere, so
/// MCP content consent / refresh re-authorization (`isStaffAnywhere`) must fail.
func demoteToStudentEverywhere(username: String, on app: Application) async throws {
    guard let user = try await APIUser.query(on: app.db).filter(\.$username == username).first()
    else { return }
    let userID = try user.requireID()
    for enrollment in try await APICourseEnrollment.query(on: app.db)
        .filter(\.$userID == userID).all()
    {
        enrollment.role = .student
        try await enrollment.save(on: app.db)
    }
}

// MARK: - Login helper

/// Hashes a password at the minimum bcrypt cost (4) for test fixtures.
///
/// Production hashing uses the default cost (12, ~150 ms). Test security is
/// irrelevant, but running a cost-12 hash + verify for every login across the
/// parallel suite saturates the CI runner (a 4-CPU box with no quota, measured
/// 2026-09-16 by the StarvationRecorder arming line; it was 2 cores when this
/// was written) — under the nightly coverage
/// build that CPU starvation slows test-app/login setup enough to flake
/// auth-dependent tests (303/401 / ~80 s stalls). bcrypt verify reads the cost
/// from the stored hash, so logins against these fixtures are fast too.
///
/// This only changes *test fixture* hashes. It does NOT touch the app's
/// configured password hasher, so `LocalAuthProvider`'s timing-equalizer (the
/// account-enumeration defense exercised by
/// `loginWithUnknownUserStillRunsBcryptVerify`) still runs at the production
/// cost.
func testPasswordHash(_ password: String) throws -> String {
    try Bcrypt.hash(password, cost: 4)
}

/// Creates `username` in the database (if not already present) with `role`,
/// then performs the full two-step GET /login → POST /login flow so the CSRF
/// token is valid. Returns the authenticated session cookie.
@discardableResult
func loginUser(
    username: String,
    password: String,
    role: String,
    on app: Application
) async throws -> String {
    if try await APIUser.query(on: app.db).filter(\.$username == username).first() == nil {
        let hash = try testPasswordHash(password)
        let user = APIUser(username: username, passwordHash: hash, role: role)
        try await user.save(on: app.db)
    }

    // Step 1: GET /login to generate a session and CSRF token.
    let (token, sessionCookie) = try await csrfFields(for: "/login", on: app)

    // Step 2: POST /login with the CSRF token bound to that session.
    var authCookie = sessionCookie
    try await app.asyncTest(
        .POST, "/login",
        beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(
                ["username": username, "password": password, "_csrf": token],
                as: .urlEncodedForm
            )
        },
        afterResponse: { res in
            // Use the new cookie if the session was rotated, otherwise keep the old one.
            if let c = res.headers.first(name: .setCookie) { authCookie = c }
        })
    return authCookie
}

/// Explicit-roster promotion: an admin promotes an already-enrolled user to a
/// per-course instructor. Teaching authority is per-course now (#417 Slice G2):
/// login auto-enrolls a non-admin as a `.student` and there is NO auto-grant, so
/// suites whose `.auto` fixtures used to rely on "auto-enroll the instructor on
/// login" call this after `loginUser(role: "instructor")` to simulate the admin
/// promotion. Upgrades every `.student` enrollment the user holds to
/// `.instructor` (a fresh test instructor's only enrollments are the ones login
/// just auto-created); anything enrolled explicitly at another role is untouched.
func promoteToInstructor(_ username: String, on app: Application) async throws {
    guard let user = try await APIUser.query(on: app.db).filter(\.$username == username).first(),
        let userID = user.id
    else { return }
    for enrollment in try await APICourseEnrollment.query(on: app.db)
        .filter(\.$userID == userID).all() where enrollment.role == .student
    {
        enrollment.role = .instructor
        try await enrollment.save(on: app.db)
    }
}
