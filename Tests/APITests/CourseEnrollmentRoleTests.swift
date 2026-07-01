// Tests/APITests/CourseEnrollmentRoleTests.swift
//
// Per-course roles (docs/multi-course-roles.md):
//   Phase 1 — the `course_enrollments.role` column, its typed accessor, and the
//     behaviour-preserving backfill from each enrolled user's global role.
//   Phase 2 — the read path: `enrolledCoursesWithRoles` and the nav predicate
//     `isInstructorInActiveCourse`.
//   Phase 3 — the auth chokepoint: `CourseRole` ordering and
//     `requireCourseRole(atLeast:)`.
//   Phase 4a — `saveSeededEnrollment`: new enrollments seed their role from the
//     user's global role.

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
        #expect(CourseRole.ta.rawValue == "ta")
        #expect(CourseRole.instructor.rawValue == "instructor")
        #expect(CourseRole(rawValue: "instructor") == .instructor)
        #expect(CourseRole(rawValue: "ta") == .ta)  // the TA rung (#417 Slice E)
        #expect(CourseRole(rawValue: "wizard") == nil)
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
    @Test func instructorInActiveCourseReflectsPerCourseRole() {
        func context(globalRole: LegacyGlobalRole, active: CourseContext?) -> CurrentUserContext {
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
        // Phase 5: authority is purely per-course — a global instructor whose
        // per-course role is student does NOT get the instructor tab here.
        #expect(context(globalRole: .instructor, active: course(.student)).isInstructorInActiveCourse == false)
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
        // TA sits strictly between student and instructor (#417 Slice E).
        #expect(CourseRole.student < CourseRole.ta)
        #expect(CourseRole.ta < CourseRole.instructor)
        #expect(CourseRole.ta >= .ta)
        #expect(CourseRole.instructor >= .ta)
        #expect(!(CourseRole.ta >= .instructor))  // a TA is NOT an instructor
        #expect(CourseRole.ta >= .student)  // ...but outranks a student
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

    // MARK: - Enrollment seeding (Phase 4a)

    /// New enrollments seed their per-course role from the user's *deployment*
    /// role: an admin becomes a per-course instructor, everyone else a student.
    /// Teaching authority is per-course now (#417 Slice G2) — a plain user (or a
    /// legacy global-`instructor` role string) auto-enrolls as a student, and
    /// the roster grants staff explicitly. Exercises both overloads.
    @Test func saveSeededEnrollmentSeedsRoleFromDeploymentRole() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try await configureTestDatabase(app)

            let course = APICourse(code: "CS101", name: "Intro", enrollmentMode: .closed)
            try await course.save(on: app.db)
            let courseID = try course.requireID()

            // A user still carrying the retired `instructor` role string is NOT
            // an admin, so it no longer auto-seeds staff.
            let legacyInstructor = makeUser(role: .instructor)
            let admin = makeUser(role: .admin)
            let student = makeUser(role: .student)
            for user in [legacyInstructor, admin, student] { try await user.save(on: app.db) }

            try await saveSeededEnrollment(for: legacyInstructor, courseID: courseID, on: app.db)
            try await saveSeededEnrollment(userID: try admin.requireID(), courseID: courseID, on: app.db)
            try await saveSeededEnrollment(userID: try student.requireID(), courseID: courseID, on: app.db)

            #expect(
                try await courseRole(of: legacyInstructor, on: app.db) == .student,
                "a legacy global-instructor string no longer auto-seeds staff — the roster grants it")
            #expect(try await courseRole(of: admin, on: app.db) == .instructor, "admin seeds to instructor")
            #expect(try await courseRole(of: student, on: app.db) == .student)
        }
    }

    // MARK: - Write access / archived-course block (Slice A of #417)

    /// `requireCourseWriteAccess` layers the archived-course read-only rule on
    /// top of `requireCourseRole`: a per-course instructor may write to an
    /// active course but not an archived one; a per-course student is forbidden
    /// regardless; and an admin bypasses both the role check and the archived
    /// block (admins administer the deployment and own unarchiving). The
    /// instructor and student are enrolled with the same role in *both* courses,
    /// so archival is the only variable across the two.
    @Test func requireCourseWriteAccessBlocksArchivedAndEnforcesRole() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try await configureTestDatabase(app)

            let active = APICourse(code: "CS101", name: "Intro", enrollmentMode: .closed)
            let archived = APICourse(code: "CS999", name: "Retired", enrollmentMode: .closed)
            archived.isArchived = true
            for course in [active, archived] { try await course.save(on: app.db) }
            let activeID = try active.requireID()
            let archivedID = try archived.requireID()

            // All non-admins are global students — authority is per-course.
            let instructor = makeUser(role: .student)
            let student = makeUser(role: .student)
            let admin = makeUser(role: .admin)  // not enrolled anywhere
            for user in [instructor, student, admin] { try await user.save(on: app.db) }

            for courseID in [activeID, archivedID] {
                try await APICourseEnrollment(
                    userID: try instructor.requireID(), courseID: courseID, role: .instructor
                ).save(on: app.db)
                try await APICourseEnrollment(
                    userID: try student.requireID(), courseID: courseID, role: .student
                ).save(on: app.db)
            }

            // Per-course instructor: may write to the active course…
            try await requireCourseWriteAccess(caller: instructor, courseID: activeID, db: app.db)
            // …but not the archived one (read-only for instructors/TAs).
            await #expect(throws: Abort.self) {
                try await requireCourseWriteAccess(caller: instructor, courseID: archivedID, db: app.db)
            }

            // Per-course student: forbidden on the active course (role too low),
            // and on the archived one.
            await #expect(throws: Abort.self) {
                try await requireCourseWriteAccess(caller: student, courseID: activeID, db: app.db)
            }
            await #expect(throws: Abort.self) {
                try await requireCourseWriteAccess(caller: student, courseID: archivedID, db: app.db)
            }

            // Admin bypasses both the role check and the archived block.
            try await requireCourseWriteAccess(caller: admin, courseID: activeID, db: app.db)
            try await requireCourseWriteAccess(caller: admin, courseID: archivedID, db: app.db)
        }
    }

    // MARK: - Last-instructor guard (Slice B of #417)

    /// `ensureNotLastInstructor` stops a non-admin from removing or demoting a
    /// course's only instructor (which would orphan it), while admins — who can
    /// always re-grant — are exempt. Once a second instructor exists, either can
    /// be removed.
    @Test func ensureNotLastInstructorGuardsCourseFromOrphaning() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try await configureTestDatabase(app)

            let course = APICourse(code: "CS101", name: "Intro", enrollmentMode: .closed)
            try await course.save(on: app.db)
            let courseID = try course.requireID()

            let inst1 = makeUser(role: .student)  // per-course instructor below
            let inst2 = makeUser(role: .student)
            let admin = makeUser(role: .admin)
            for user in [inst1, inst2, admin] { try await user.save(on: app.db) }
            try await APICourseEnrollment(
                userID: try inst1.requireID(), courseID: courseID, role: .instructor
            ).save(on: app.db)

            // Only one instructor: a non-admin cannot remove them…
            await #expect(throws: Abort.self) {
                try await ensureNotLastInstructor(
                    caller: inst1, courseID: courseID, removing: try inst1.requireID(), db: app.db)
            }
            // …but an admin can (they can re-grant).
            try await ensureNotLastInstructor(
                caller: admin, courseID: courseID, removing: try inst1.requireID(), db: app.db)

            // With a second instructor, a non-admin may remove either one.
            try await APICourseEnrollment(
                userID: try inst2.requireID(), courseID: courseID, role: .instructor
            ).save(on: app.db)
            try await ensureNotLastInstructor(
                caller: inst1, courseID: courseID, removing: try inst1.requireID(), db: app.db)
            try await ensureNotLastInstructor(
                caller: inst1, courseID: courseID, removing: try inst2.requireID(), db: app.db)
        }
    }

    // MARK: - Helpers

    /// Test-only stand-in for the retired global `student` / `instructor`
    /// roles. The deployment role enum collapsed to `user` / `admin` / `mcp`
    /// (#417 Slice G2), but these role-model tests still construct users
    /// carrying the legacy role strings a pre-collapse production row would
    /// have (the backfill reads them). `.rawValue` is faithful, so behaviour is
    /// identical to the old `UserRole` cases.
    private enum LegacyGlobalRole {
        case student, instructor, admin
        var rawValue: String {
            switch self {
            case .student: return "student"
            case .instructor: return "instructor"
            case .admin: return UserRole.admin.rawValue
            }
        }
    }

    private func makeUser(role: LegacyGlobalRole) -> APIUser {
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
