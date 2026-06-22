// Tests/APITests/CourseEnrollmentRoleTests.swift
//
// Per-course roles (docs/multi-course-roles.md):
//   Phase 1 — the `course_enrollments.role` column, its typed accessor, and the
//     behaviour-preserving backfill from each enrolled user's global role.
//   Phase 2 — the read path: `enrolledCoursesWithRoles` and the nav predicate
//     `isInstructorInActiveCourse`.
//   Phase 3 — the auth chokepoint: `CourseRole` ordering and
//     `requireCourseRole(atLeast:)`.

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

    // MARK: - Read path (Phase 2)

    /// `isInstructorInActiveCourse` (which the nav keys off) is driven by the
    /// active course's per-course role, with a transitional fallback to the
    /// global role.
    @Test func instructorInActiveCourseReflectsPerCourseRoleAndGlobalFallback() {
        func context(globalRole: UserRole, active: CourseContext?) -> CurrentUserContext {
            let user = APIUser(username: "u", passwordHash: "x", role: globalRole.rawValue)
            return CurrentUserContext(
                user: user, activeCourse: active, enrolledCourses: active.map { [$0] } ?? [])
        }
        func course(_ role: CourseRole) -> CourseContext {
            CourseContext(id: UUID().uuidString, code: "CS101", name: "Intro", isActive: true, role: role)
        }

        // No active course → never instructor-in-course, whatever the global role.
        #expect(context(globalRole: .instructor, active: nil).isInstructorInActiveCourse == false)
        // Global student, per-course student → no instructor surfaces.
        #expect(context(globalRole: .student, active: course(.student)).isInstructorInActiveCourse == false)
        // The Phase 2 point: a global *student* with a per-course instructor role → yes.
        #expect(context(globalRole: .student, active: course(.instructor)).isInstructorInActiveCourse == true)
        // Transitional fallback: a global instructor keeps the tab even where the
        // per-course role is still student (the fallback is removed in Phase 5).
        #expect(context(globalRole: .instructor, active: course(.student)).isInstructorInActiveCourse == true)
        // Admin keeps deployment-wide instructor surfaces.
        #expect(context(globalRole: .admin, active: course(.student)).isInstructorInActiveCourse == true)
    }

    /// `enrolledCoursesWithRoles` returns each enrolled (non-archived) course
    /// paired with the caller's per-course role, sorted by code — the resolver
    /// the nav's active-course role is read from.
    @Test func enrolledCoursesWithRolesCarriesPerCourseRole() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try await configureTestDatabase(app)

            let user = makeUser(role: .student)
            try await user.save(on: app.db)
            let userID = try user.requireID()

            let cs101 = APICourse(code: "CS101", name: "Intro", enrollmentMode: .closed)
            let cs246 = APICourse(code: "CS246", name: "OOP", enrollmentMode: .closed)
            let archived = APICourse(code: "CS999", name: "Retired", enrollmentMode: .closed)
            archived.isArchived = true
            for course in [cs101, cs246, archived] { try await course.save(on: app.db) }

            try await APICourseEnrollment(
                userID: userID, courseID: try cs101.requireID(), role: .student
            ).save(on: app.db)
            try await APICourseEnrollment(
                userID: userID, courseID: try cs246.requireID(), role: .instructor
            ).save(on: app.db)
            try await APICourseEnrollment(
                userID: userID, courseID: try archived.requireID(), role: .instructor
            ).save(on: app.db)

            let pairs = try await enrolledCoursesWithRoles(for: userID, on: app.db)

            // Archived course excluded; the rest sorted by code, role carried through.
            #expect(pairs.map(\.course.code) == ["CS101", "CS246"])
            #expect(pairs.map(\.role) == [.student, .instructor])
        }
    }

    // MARK: - Auth path (Phase 3)

    @Test func courseRoleLadderOrdersByPrivilege() {
        #expect(CourseRole.student < CourseRole.instructor)
        #expect(CourseRole.instructor >= .instructor)
        #expect(CourseRole.student >= .student)
        #expect(!(CourseRole.instructor < CourseRole.student))
    }

    /// `requireCourseRole` authorizes by the *per-course* role: a global student
    /// enrolled as a per-course instructor passes the `.instructor` bar, while a
    /// global student enrolled as a student does not. Admins bypass; an
    /// unenrolled non-admin is forbidden even at `.student`.
    @Test func requireCourseRoleEnforcesPerCourseRole() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try await configureTestDatabase(app)

            let course = APICourse(code: "CS101", name: "Intro", enrollmentMode: .closed)
            try await course.save(on: app.db)
            let courseID = try course.requireID()

            // All non-admins are global *students* — proving authority is per-course.
            let asStudent = makeUser(role: .student)
            let asInstructor = makeUser(role: .student)
            let unenrolled = makeUser(role: .student)
            let admin = makeUser(role: .admin)  // not enrolled anywhere
            for user in [asStudent, asInstructor, unenrolled, admin] { try await user.save(on: app.db) }

            try await APICourseEnrollment(
                userID: try asStudent.requireID(), courseID: courseID, role: .student
            ).save(on: app.db)
            try await APICourseEnrollment(
                userID: try asInstructor.requireID(), courseID: courseID, role: .instructor
            ).save(on: app.db)

            // Per-course student: meets .student, not .instructor.
            try await requireCourseRole(caller: asStudent, courseID: courseID, atLeast: .student, db: app.db)
            await #expect(throws: Abort.self) {
                try await requireCourseRole(
                    caller: asStudent, courseID: courseID, atLeast: .instructor, db: app.db)
            }

            // Per-course instructor (a global student!): meets .instructor.
            try await requireCourseRole(
                caller: asInstructor, courseID: courseID, atLeast: .instructor, db: app.db)

            // Admin bypasses without an enrollment.
            try await requireCourseRole(caller: admin, courseID: courseID, atLeast: .instructor, db: app.db)

            // Unenrolled non-admin is forbidden even at the student bar.
            await #expect(throws: Abort.self) {
                try await requireCourseRole(
                    caller: unenrolled, courseID: courseID, atLeast: .student, db: app.db)
            }

            // requireCourseEnrollment still behaves as the `.student` case.
            try await requireCourseEnrollment(caller: asStudent, courseID: courseID, db: app.db)
            await #expect(throws: Abort.self) {
                try await requireCourseEnrollment(caller: unenrolled, courseID: courseID, db: app.db)
            }
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
