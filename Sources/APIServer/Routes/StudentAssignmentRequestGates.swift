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

func requireOpenStudentAssignment(
    for testSetupID: String,
    user: APIUser,
    gate: StudentAssignmentGate,
    on req: Request,
    now: Date = Date()
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
            testSetupID: testSetupID, assignment: assignment, user: user, on: req, now: now)
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
/// instructor locked out of their own contest has no way in.
private func requireOpenActivityWindow(
    testSetupID: String,
    assignment: APIAssignment,
    user: APIUser,
    on req: Request,
    now: Date
) async throws {
    guard let setup = try await APITestSetup.find(testSetupID, on: req.db),
        let window = setup.decodedManifest()?.activity?.window,
        !window.accepts(at: now)
    else { return }
    if try await isCourseStaff(user, inCourse: assignment.courseID, db: req.db) { return }

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
