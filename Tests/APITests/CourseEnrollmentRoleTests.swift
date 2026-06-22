// Tests/APITests/CourseEnrollmentRoleMigrationTests.swift
//
// Phase 1 of per-course roles (docs/multi-course-roles.md): the
// `course_enrollments.role` column, its typed accessor, and the
// behaviour-preserving backfill that seeds each enrollment's role from the
// enrolled user's global role.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct CourseEnrollmentRoleTests {

    // MARK: - Core type + model accessor (no DB)

    @Test func courseRoleRawValuesRoundTrip() {
        #expect(CourseRole.student.rawValue == "student")
        #expect(CourseRole.instructor.rawValue == "instructor")
        #expect(CourseRole(rawValue: "instructor") == .instructor)
        #expect(CourseRole(rawValue: "ta") == nil)  // not a rung yet
    }

    @Test func roleAccessorDefaultsToStudentForMissingOrUnknownRaw() {
        let enrollment = APICourseEnrollment(userID: UUID(), courseID: UUID())
        // init default
        #expect(enrollment.role == .student)
        #expect(enrollment.roleRaw == "student")

        // explicit nil → defensive default
        enrollment.roleRaw = nil
        #expect(enrollment.role == .student)

        // unknown stored value → defensive default
        enrollment.roleRaw = "wizard"
        #expect(enrollment.role == .student)

        // setter writes the raw string
        enrollment.role = .instructor
        #expect(enrollment.roleRaw == "instructor")
    }

    @Test func initStoresInstructorRole() {
        let enrollment = APICourseEnrollment(userID: UUID(), courseID: UUID(), role: .instructor)
        #expect(enrollment.role == .instructor)
        #expect(enrollment.roleRaw == "instructor")
    }

    // MARK: - Backfill (DB)

    /// The backfill seeds each still-unset enrollment role from the enrolled
    /// user's *global* role: a global instructor (or admin, which implies
    /// instructor) becomes a per-course instructor; everyone else a student.
    /// This is what makes applying the migration behaviour-preserving.
    @Test func backfillSeedsRoleFromGlobalRole() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try await configureTestDatabase(app)

            let course = APICourse(code: "CS101", name: "Intro", enrollmentMode: .closed)
            try await course.save(on: app.db)
            let courseID = try course.requireID()

            // One user per global role.
            let instructor = makeUser(role: .instructor)
            let admin = makeUser(role: .admin)
            let student = makeUser(role: .student)
            for user in [instructor, admin, student] { try await user.save(on: app.db) }

            // Enrollments with a NULL role, simulating pre-migration rows.
            for user in [instructor, admin, student] {
                let enrollment = APICourseEnrollment(userID: try user.requireID(), courseID: courseID)
                enrollment.roleRaw = nil
                try await enrollment.save(on: app.db)
            }

            try await AddCourseEnrollmentRole().backfillRoles(on: app.db)

            #expect(try await courseRole(of: instructor, on: app.db) == .instructor)
            #expect(try await courseRole(of: admin, on: app.db) == .instructor, "admin implies instructor")
            #expect(try await courseRole(of: student, on: app.db) == .student)
        }
    }

    /// The backfill only touches NULL roles — an enrollment already carrying a
    /// role is left alone, so re-running it is safe.
    @Test func backfillLeavesExistingRolesUntouched() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try await configureTestDatabase(app)

            let course = APICourse(code: "CS101", name: "Intro", enrollmentMode: .closed)
            try await course.save(on: app.db)
            let courseID = try course.requireID()

            // A *student* global role, but the enrollment is explicitly an
            // instructor (the shape a future TA / co-instructor takes).
            let user = makeUser(role: .student)
            try await user.save(on: app.db)
            let enrollment = APICourseEnrollment(
                userID: try user.requireID(), courseID: courseID, role: .instructor)
            try await enrollment.save(on: app.db)

            try await AddCourseEnrollmentRole().backfillRoles(on: app.db)

            let reloaded = try #require(try await APICourseEnrollment.find(enrollment.id, on: app.db))
            #expect(reloaded.role == .instructor, "a non-null role must not be overwritten by the global role")
        }
    }

    // MARK: - Helpers

    private func makeUser(role: UserRole) -> APIUser {
        APIUser(
            username: "\(role.rawValue)_\(UUID().uuidString.prefix(8))",
            passwordHash: "x",
            role: role.rawValue
        )
    }

    private func courseRole(of user: APIUser, on db: Database) async throws -> CourseRole {
        let enrollment = try #require(
            try await APICourseEnrollment.query(on: db)
                .filter(\.$userID == user.requireID())
                .first()
        )
        return enrollment.role
    }
}
