// APIServer/Helpers/CourseAccessHelpers.swift
//
// Shared course-visibility and enrollment-access policy. The web routes and
// the MCP tools both resolve "which courses can this user act on" and "may
// this user touch this course" through the helpers here, so the two surfaces
// cannot drift.
//
// Rule: everyone — instructors included — must be enrolled in the specific
// course that owns the resource. Admins are the one bypass: they administer
// the whole deployment (and can grant themselves enrollment anyway), so
// binding them here adds friction without adding security. Their MCP agents
// are still enrollment-scoped (see ToolContext.authorizeCourseAccess), which
// keeps agent scope ⊆ human scope for every role.

import Core
import Fluent
import Vapor

/// Throws `.forbidden` unless `caller` is an admin or holds an enrollment in
/// `courseID` whose per-course role is at least `minimum`. Admins bypass (they
/// administer the whole deployment and can grant themselves enrollment anyway).
/// This is the role-aware chokepoint for course access (Phase 3 of
/// docs/multi-course-roles.md); `requireCourseEnrollment` is its `.student`
/// case.
///
/// Authority is purely per-course here — there is no "global instructor"
/// bypass. Today the only production callers pass `.student` (via
/// `requireCourseEnrollment`), and every enrolled user is at least a student,
/// so behaviour is identical to the prior enrollment-only check. The
/// `.instructor` bar is wired into the authoring surfaces in Phase 4, once
/// per-course roles are authorable; until then it is exercised only by tests.
func requireCourseRole(
    caller: APIUser, courseID: UUID, atLeast minimum: CourseRole, db: Database
) async throws {
    guard !caller.isAdmin else { return }
    guard let callerID = caller.id else { throw Abort(.unauthorized) }
    guard let role = try await courseRole(of: callerID, inCourse: courseID, db: db) else {
        throw Abort(.forbidden)
    }
    guard role >= minimum else { throw Abort(.forbidden) }
}

/// Throws `.forbidden` unless `caller` is an admin or is enrolled in the
/// course identified by `courseID`. Instructors get no bypass: historically
/// any instructor account could fetch another course's content — including
/// test setups carrying secret tests and reference solutions — by URL, even
/// though the dashboard never showed it to them. Now the `.student` case of
/// `requireCourseRole`.
func requireCourseEnrollment(caller: APIUser, courseID: UUID, db: Database) async throws {
    try await requireCourseRole(caller: caller, courseID: courseID, atLeast: .student, db: db)
}

/// The caller's per-course role in `courseID`, or nil if they hold no
/// enrollment there. The single role read behind `requireCourseRole`.
func courseRole(of userID: UUID, inCourse courseID: UUID, db: Database) async throws -> CourseRole? {
    try await APICourseEnrollment.query(on: db)
        .filter(\.$userID == userID)
        .filter(\.$course.$id == courseID)
        .first()?
        .role
}

/// True when the user holds an enrollment row in course `courseID`. The single
/// enrollment predicate behind both the web guard above and the MCP tools'
/// `authorizeCourseAccess`. Deliberately carries no role bypass — role policy
/// stays with the callers.
func userIsEnrolled(userID: UUID, inCourse courseID: UUID, db: Database) async throws -> Bool {
    try await APICourseEnrollment.query(on: db)
        .filter(\.$userID == userID)
        .filter(\.$course.$id == courseID)
        .count() > 0
}

/// The courses the user can act on, dashboard-style: the non-archived courses
/// they hold an enrollment row in, sorted by code. The single visibility
/// resolver behind the web tab strip (`resolveActiveCourse`) and the MCP
/// listing surface (`list_courses`, `resources/list`). No role widens this
/// set: admins see — and their agents may act on — exactly what they are
/// enrolled in. Defined in terms of `enrolledCoursesWithRoles` so the two
/// can't drift on which courses are visible or in what order.
func enrolledCourses(for userID: UUID, on db: Database) async throws -> [APICourse] {
    try await enrolledCoursesWithRoles(for: userID, on: db).map(\.course)
}

/// Like `enrolledCourses`, but pairs each course with the caller's per-course
/// role from the enrollment row (Phase 2 of docs/multi-course-roles.md). The
/// web read path carries this into the nav; the role is web-only and never
/// widens the visible set, and MCP keeps using the role-free `enrolledCourses`.
func enrolledCoursesWithRoles(
    for userID: UUID, on db: Database
) async throws -> [(course: APICourse, role: CourseRole)] {
    let enrollments = try await APICourseEnrollment.query(on: db)
        .filter(\.$userID == userID)
        .with(\.$course)
        .all()
    return
        enrollments
        .filter { !$0.course.isArchived }
        .sorted { $0.course.code < $1.course.code }
        .map { (course: $0.course, role: $0.role) }
}

/// Instructor-authorization for a specific course: admits an admin or a
/// per-course instructor (an `.instructor` enrollment). Used by the param-taking
/// `/instructor` endpoints so a course's instructor can't be driven against
/// another course. Instructor authority is purely per-course as of
/// multi-course-roles Phase 5 (the global instructor role no longer grants it).
func requireCourseInstructor(caller: APIUser, courseID: UUID, db: Database) async throws {
    try await requireCourseRole(caller: caller, courseID: courseID, atLeast: .instructor, db: db)
}

/// True when `user` may act with *staff* visibility for `courseID`: an admin,
/// or a per-course enrollment role of at least `.ta`. This is the per-course
/// replacement for the global `APIUser.isInstructor` view/access gate (#417
/// Slice G) — a viewer sees instructor-level detail (all tiers, other students'
/// submissions, solution files) only for the courses they actually staff, not
/// deployment-wide. TAs count as staff (they grade), matching Slice E.
func isCourseStaff(_ user: APIUser, inCourse courseID: UUID, db: Database) async throws -> Bool {
    if user.isAdmin { return true }
    guard let userID = user.id else { return false }
    guard let role = try await courseRole(of: userID, inCourse: courseID, db: db) else { return false }
    return role >= .ta
}

/// True when `user` is staff (role >= `.ta`) in *any* non-archived enrolled
/// course, or an admin. The coarse analog of `isCourseStaff` for gates that
/// have no single resource course in scope (the MCP content-tool gate, the
/// OAuth content-scope consent gate, the user-file namespace). Downstream
/// per-course checks still apply, so this only decides "may this account touch
/// the staff surface at all", never which course it may act on.
func isStaffAnywhere(_ user: APIUser, db: Database) async throws -> Bool {
    if user.isAdmin { return true }
    guard let userID = user.id else { return false }
    return try await APICourseEnrollment.query(on: db)
        .filter(\.$userID == userID)
        .group(.or) { or in
            or.filter(\.$roleRaw == CourseRole.ta.rawValue)
            or.filter(\.$roleRaw == CourseRole.instructor.rawValue)
        }
        .count() > 0
}

/// The UUID of the course that owns `submission`, resolved through its test
/// setup (`test_setups.course_id`). Nil only if the setup row is missing.
/// Used to scope per-course staff checks on the submission view/download/query
/// paths (#417 Slice G).
func courseID(ofSubmission submission: APISubmission, on db: Database) async throws -> UUID? {
    try await APITestSetup.find(submission.testSetupID, on: db)?.courseID
}

/// Whether `user` is staff (TA+ or admin) for `submission`'s course — the
/// per-course view gate for the submission view/download paths. False when the
/// submission's setup (hence course) can't be resolved (#417 Slice G).
func isSubmissionStaff(
    _ user: APIUser, submission: APISubmission, on db: Database
) async throws
    -> Bool
{
    guard let owningCourseID = try await courseID(ofSubmission: submission, on: db) else {
        return false
    }
    return try await isCourseStaff(user, inCourse: owningCourseID, db: db)
}

/// Authorizes a *write* to a per-course resource. The caller must satisfy
/// `requireCourseRole(atLeast:)` for `courseID` (admin bypass) **and** the
/// course must not be archived. Archived courses are read-only for
/// instructors and TAs — editing assignments/tests, mutating enrollment, and
/// retesting are blocked once a course is archived, while grade audits and
/// lookups stay readable (the read helpers carry no archived block). Admins
/// remain write-exempt: they administer the whole deployment, and unarchiving
/// is an admin-only action.
///
/// Mutating per-course handlers call this in place of `requireCourseInstructor`,
/// scoping the check to the *resource's own* course so an instructor of one
/// course can't drive a write against another by URL — the per-course
/// authorization the `/instructor` group middleware (which only sees the
/// caller's active course) can't enforce. See docs/multi-course-roles.md.
func requireCourseWriteAccess(
    caller: APIUser, courseID: UUID, atLeast minimum: CourseRole = .instructor, db: Database
) async throws {
    try await requireCourseRole(caller: caller, courseID: courseID, atLeast: minimum, db: db)
    guard !caller.isAdmin else { return }
    guard let course = try await APICourse.find(courseID, on: db) else {
        throw Abort(.notFound, reason: "Course not found.")
    }
    guard !course.isArchived else {
        throw Abort(.forbidden, reason: "This course is archived and is read-only.")
    }
}

/// Guards against orphaning a course (#417 Slice B). Throws `.conflict` if
/// removing or downgrading the instructor enrollment held by `userID` would
/// leave `courseID` with zero instructors. Admins are exempt — they can always
/// re-grant — so an admin may still force the change; the guard only stops a
/// non-admin instructor from self-demoting or unenrolling the course's last
/// instructor without transferring the role first.
func ensureNotLastInstructor(
    caller: APIUser, courseID: UUID, removing userID: UUID, db: Database
) async throws {
    guard !caller.isAdmin else { return }
    let otherInstructors = try await APICourseEnrollment.query(on: db)
        .filter(\.$course.$id == courseID)
        .filter(\.$roleRaw == CourseRole.instructor.rawValue)
        .filter(\.$userID != userID)
        .count()
    guard otherInstructors > 0 else {
        throw Abort(
            .conflict,
            reason:
                "A course must keep at least one instructor. Assign another instructor before removing or demoting this one."
        )
    }
}

// MARK: - Enrollment creation (role seeding)

/// Creates and saves a new enrollment for `user` in `courseID`, seeding the
/// per-course role from the user's current global role: a global instructor or
/// admin becomes a per-course instructor, everyone else a student. The single
/// place the creation-time seeding rule lives (Phase 4a of
/// docs/multi-course-roles.md), so moving authorization onto the per-course
/// role later doesn't drop anyone's existing access — the roster can override
/// afterward. Callers handle their own "already enrolled?" dedup.
func saveSeededEnrollment(for user: APIUser, courseID: UUID, on db: Database) async throws {
    try await APICourseEnrollment(
        userID: try user.requireID(), courseID: courseID,
        role: user.isInstructor ? .instructor : .student
    ).save(on: db)
}

/// `saveSeededEnrollment` for callers that hold only the user's ID; loads the
/// user to read its global role. A missing user falls back to `.student`.
func saveSeededEnrollment(userID: UUID, courseID: UUID, on db: Database) async throws {
    let isInstructor = try await APIUser.find(userID, on: db)?.isInstructor ?? false
    try await APICourseEnrollment(
        userID: userID, courseID: courseID,
        role: isInstructor ? .instructor : .student
    ).save(on: db)
}
