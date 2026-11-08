// APIServer/Routes/StudentAssignmentRequestGates.swift
//
// The assignment gates a request handler runs, which read the request's
// per-request course-role memo (#1382 item 3) so the several checks one page
// load makes share one enrollment read. The policies they apply live in
// `Services/AssignmentDeadlineService.swift` and
// `Services/NotebookWorkingCopyStore.swift`, which take a database and never a
// `Request`; these moved up from there in #1732.

import Core
import Fluent
import Foundation
import Vapor

/// `isAssignmentEffectivelyOpen` for request handlers: the staff check reads
/// the request's role memo (#1382 item 3), so the several open/closed checks
/// a page load performs share one enrollment read.
func isAssignmentEffectivelyOpen(
    _ assignment: APIAssignment,
    for user: APIUser,
    req: Request,
    now: Date = Date()
) async throws -> Bool {
    let isStaff = try await req.cachedIsCourseStaff(user, inCourse: assignment.courseID)
    return try await isAssignmentEffectivelyOpenResolved(
        assignment, for: user, isStaff: isStaff, on: req.db, now: now)
}

/// `setup` is the row for `testSetupID` when the caller already holds it, so
/// the activity-window gate reads its manifest without finding it again. A
/// row for any other ID is ignored.
func requireOpenStudentAssignment(
    for testSetupID: String,
    user: APIUser,
    gate: StudentAssignmentGate,
    on req: Request,
    now: Date = Date(),
    setup: APITestSetup? = nil
) async throws -> APIAssignment? {
    guard
        let assignment = try await assignmentByTestSetupID(testSetupID, on: req.db)
    else {
        return nil
    }

    // Enforce course enrollment before any open/closed check.  Without this,
    // a student in course A who learns a testSetupID belonging to course B
    // (UUIDs are exposed in submission URLs, shared instructor pages, and
    // vanity-URL resolutions) can submit to that assignment and pollute
    // foreign instructors' queues.  Instructors and admins bypass via
    // `requireCourseEnrollment`'s own short-circuit.
    try await req.cachedRequireCourseEnrollment(caller: user, courseID: assignment.courseID)

    // Lazy schedule enforcement, both directions. The close has always been
    // enforced here as a safety net under the periodic sweep; the open gets
    // the same treatment so a student following a direct link to a scheduled
    // assignment whose open date has arrived is let in even if the background
    // sweep is not running (the dashboard loader applies the same repair).
    _ = try await openScheduledAssignment(assignment, on: req.db, logger: req.logger, now: now)
    _ = try await closeAssignmentIfExpired(assignment, on: req.db, logger: req.logger, now: now)

    // Preview is open for course staff and closed for students — handled
    // uniformly by isAssignmentEffectivelyOpen, so staff use it via the normal
    // open path (bundled solution/tests, normal submission) with no special case.
    let open = try await isAssignmentEffectivelyOpen(assignment, for: user, req: req, now: now)
    guard open else {
        throw AssignmentSubmissionGateError.closed
    }
    if gate == .submission {
        try await requireOpenActivityWindow(
            testSetupID: testSetupID, heldSetup: setup, assignment: assignment, user: user, on: req, now: now)
    }
    return assignment
}

/// Refuses a submission landing outside a class activity's live-session
/// window (docs/class-activities.md).
///
/// ONE CHOKEPOINT, reached through `requireOpenStudentAssignment`, because
/// every submission door already goes through that: the web upload, the
/// notebook submit, the browser result and the browser failover. Wiring it at
/// each door instead is how the class-badge award reached only half the class
/// until audit A2 found it.
///
/// Course staff are not gated. They run the session — starting it, testing the
/// bot, submitting a demonstration entry while the room watches — and an
/// instructor locked out of their own contest has no way in. The staff check
/// reads the request's role memo, which the enrollment gate has filled.
private func requireOpenActivityWindow(
    testSetupID: String,
    heldSetup: APITestSetup?,
    assignment: APIAssignment,
    user: APIUser,
    on req: Request,
    now: Date
) async throws {
    let setup =
        if let heldSetup, heldSetup.id == testSetupID {
            heldSetup
        } else {
            try await APITestSetup.find(testSetupID, on: req.db)
        }
    guard let activity = setup?.decodedManifest()?.activity else { return }
    if activity.isPerGroup {
        try await requireOpenGroupSession(assignment: assignment, user: user, on: req, now: now)
        return
    }
    guard !activity.acceptsSubmissions(at: now), let window = activity.window else { return }
    if try await req.cachedIsCourseStaff(user, inCourse: assignment.courseID) { return }

    let formatter = waterlooDateTimeFormatter()
    switch window.state(at: now) {
    case .beforeOpen:
        throw AssignmentSubmissionGateError.activityNotYetOpen(
            opensAtText: window.opensAt.map(formatter.string(from:)) ?? "a later time")
    case .afterClose:
        throw AssignmentSubmissionGateError.activityClosed(
            closedAtText: window.closesAt.map(formatter.string(from:)) ?? "an earlier time")
    case .open:
        return
    }
}

/// Refuses a submission to a per-group activity (docs/lab-groups.md) from a
/// student who has never joined one of its sessions by code. In place of the
/// window, not beside it: a per-group activity carries none. A student who
/// joined may still submit after their session closes: the result grades and
/// does not rank, because the board froze at the close (maintainer decision
/// 1, `recordLeaderboardEntry`). Course staff are not gated, for the window's
/// reason.
private func requireOpenGroupSession(
    assignment: APIAssignment, user: APIUser, on req: Request, now: Date
) async throws {
    if try await req.cachedIsCourseStaff(user, inCourse: assignment.courseID) { return }
    let joined = try await ActivitySessionStore.hasJoined(
        assignmentID: assignment.requireID(), userID: user.requireID(), on: req.db)
    guard !joined else { return }
    throw AssignmentSubmissionGateError.notInGroupSession
}

extension Request {
    /// Runs the closed-assignment gate (`closedAssignmentGate`) for `user` and
    /// turns its answer into a redirect to the dashboard, or nil when the user
    /// may continue. Staff-ness for the assignment's course comes from this
    /// request's role memo.
    func closedAssignmentRedirect(
        user: APIUser,
        userID: UUID,
        assignment: APIAssignment?,
        isClosed: Bool
    ) async throws -> Response? {
        let viewerIsCourseStaff: Bool =
            if let courseID = assignment?.courseID {
                try await cachedIsCourseStaff(user, inCourse: courseID)
            } else {
                false
            }
        switch try await closedAssignmentGate(
            userID: userID, assignment: assignment, isClosed: isClosed,
            viewerIsCourseStaff: viewerIsCourseStaff, on: db)
        {
        case .allowed: return nil
        case .redirectToDashboard: return redirect(to: "/")
        }
    }
}

/// Whether a non-staff `user` may read the content of the assignment on
/// `testSetupID`: its starter notebook, its support files, its vanity link
/// (#2897).
///
/// The rule is the notebook page's own (`notebookSource`): the assignment is
/// effectively open, or the student opened it while it was. A setup with no
/// published assignment is a staff draft, so it is refused. Course staff are
/// not gated. Enrollment is the caller's own check, made before this one.
func studentMayReadAssignmentContent(
    testSetupID: String, courseID: UUID, user: APIUser, on req: Request
) async throws -> Bool {
    if try await req.cachedIsCourseStaff(user, inCourse: courseID) { return true }
    guard let assignment = try await assignmentByTestSetupID(testSetupID, on: req.db) else { return false }
    if try await isAssignmentEffectivelyOpen(assignment, for: user, req: req) { return true }
    return try await studentHasOpenedAssignment(assignment: assignment, userID: try user.requireID(), on: req.db)
}
