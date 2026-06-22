import Core
import Fluent
import Foundation
import Vapor

enum AssignmentSubmissionGateError: AbortError {
    case closed

    var status: HTTPResponseStatus {
        switch self {
        case .closed:
            return .forbidden
        }
    }

    var reason: String {
        switch self {
        case .closed:
            return "This assignment is closed and no longer accepts submissions."
        }
    }
}

func assignmentDeadlineHasPassed(_ assignment: APIAssignment, now: Date = Date()) -> Bool {
    guard let dueAt = assignment.dueAt else { return false }
    return dueAt <= now
}

func assignmentDeadlineOverrideIsActive(_ assignment: APIAssignment) -> Bool {
    assignment.deadlineOverrideActive ?? false
}

/// Decides per-student submission eligibility from already-resolved inputs.
/// `effectiveDueAt` is the later of the assignment-wide deadline and any
/// per-student extension (nil only when the assignment has no deadline at all).
///
/// `hasActiveExtension` is the decisive signal for an accommodated student: when
/// the instructor has granted this student an extension whose deadline is still
/// in the future, they may keep submitting no matter how the assignment-wide
/// state reads — open, auto-closed at the deadline, or manually closed before
/// it. An extension is an explicit, per-student accommodation; the only thing it
/// does not override is a future open date (`startsAt`), since the assignment
/// must have started before anyone — accommodated or not — can submit.
///
/// With no active extension the assignment-wide `isOpen` flag still governs: a
/// close *before* the deadline is a deliberate manual close and stays closed,
/// while a close *at/after* the deadline is the automatic sweep and likewise
/// leaves an un-extended student closed.
func isAssignmentOpenForUser(
    isOpen: Bool,
    overrideActive: Bool,
    baselineDueAt: Date?,
    effectiveDueAt: Date?,
    hasActiveExtension: Bool = false,
    startsAt: Date? = nil,
    now: Date = Date()
) -> Bool {
    // Front gate: a future open date holds the assignment closed for everyone,
    // regardless of `isOpen` or any deadline/extension state. An extension
    // lengthens the *deadline*, not the *open date*, so it does not unlock an
    // assignment that has not started yet.
    if let startsAt, now < startsAt { return false }

    // An active per-student extension reopens submission for that one student no
    // matter how the assignment closed — including a deliberate manual close
    // before the deadline. Granting an extension is an explicit instructor
    // decision to let this student keep working; without this, an extension on
    // an already-closed assignment would have no effect.
    if hasActiveExtension { return true }

    let deadlinePassed = baselineDueAt.map { $0 <= now } ?? false
    if isOpen {
        if !deadlinePassed { return true }
        if overrideActive { return true }
    } else if !deadlinePassed {
        // Closed before the deadline with no active extension — a deliberate
        // manual close stays closed.
        return false
    }
    guard let effectiveDueAt else { return false }
    return now < effectiveDueAt
}

/// The raw per-student extension date for (assignment, user), if a row exists.
/// Unlike `effectiveDueAt`, this is the extension's *own* date — never folded
/// together with the assignment-wide deadline — so callers can tell a genuine
/// accommodation apart from the baseline due date.
func studentExtensionDueAt(
    for assignment: APIAssignment,
    user: APIUser,
    on db: Database
) async throws -> Date? {
    guard let assignmentID = assignment.id, let userID = user.id else { return nil }
    return try await APIAssignmentExtension.query(on: db)
        .filter(\.$assignmentID == assignmentID)
        .filter(\.$userID == userID)
        .first()?
        .extendedDueAt
}

/// Whether a per-student extension is currently in effect: a row exists and its
/// date has not yet passed.
///
/// This is deliberately independent of the assignment-wide deadline. An
/// extension is an explicit accommodation, so as long as it has not lapsed the
/// student may keep working — even when the extension date falls *before* the
/// original due date, which is exactly what happens when an instructor closes an
/// assignment early and then grants a shorter window to one student. Tying
/// "active" to "later than the deadline" would silently lock that student out.
///
/// Computing the *effective* deadline to display (the later of the baseline and
/// the extension) is a separate concern handled by `laterDeadline`. Shared by
/// the submission gate, the dashboard gate, and the dashboard visibility filter
/// so the three never drift.
func studentHasActiveExtension(
    extensionDueAt: Date?,
    now: Date = Date()
) -> Bool {
    guard let extensionDueAt else { return false }
    return now < extensionDueAt
}

/// Whether a published assignment should appear to an enrolled student on the
/// strength of its own state alone — independent of any per-student extension
/// or prior participation, which the dashboard unions in separately.
///
/// Students see an assignment that is currently open, or one that was published
/// to the class and has since closed at its deadline (so recently-closed labs
/// stay on the dashboard and remain openable read-only, instead of silently
/// vanishing). Deliberately hidden so authoring-in-progress content never leaks:
///   - `.preview` assignments (staff-only beta state),
///   - not-yet-started assignments (a future `startsAt`),
///   - not-yet-published drafts — a `.closed` assignment that has no past due
///     date (a freshly created / cloned assignment, or one closed before its
///     deadline; those are surfaced only via an extension or prior engagement).
func assignmentVisibleToStudentByState(_ assignment: APIAssignment, now: Date = Date()) -> Bool {
    if assignment.isOpen { return true }
    // Only `.closed` is a candidate for the published-then-closed case; `.preview`
    // remains staff-only.
    guard assignment.visibility == .closed else { return false }
    if let startsAt = assignment.startsAt, now < startsAt { return false }
    guard let dueAt = assignment.dueAt, dueAt <= now else { return false }
    return true
}

func laterDeadline(baseline: Date?, extensionDueAt: Date?) -> Date? {
    guard let extensionDueAt else { return baseline }
    guard let baseline else { return extensionDueAt }
    return max(baseline, extensionDueAt)
}

/// Returns the deadline that actually applies to `user` for `assignment`,
/// consulting per-student extension rows.  A user with no extension gets
/// the assignment-wide `dueAt`; with an extension, the later of the two.
/// Returns nil only when the assignment has no deadline at all.
func effectiveDueAt(
    for assignment: APIAssignment,
    user: APIUser,
    on db: Database
) async throws -> Date? {
    let extensionDueAt = try await studentExtensionDueAt(for: assignment, user: user, on: db)
    return laterDeadline(baseline: assignment.dueAt, extensionDueAt: extensionDueAt)
}

/// Whether `user` may currently submit to `assignment`, consulting per-student
/// extension rows.  An active extension keeps submission open for one student
/// even after the assignment-wide deadline has passed and the automatic sweep
/// has flipped `isOpen` to false.  A deliberate manual close (before the
/// deadline) is still respected — see `isAssignmentOpenForUser`.
func isAssignmentEffectivelyOpen(
    _ assignment: APIAssignment,
    for user: APIUser,
    on db: Database,
    now: Date = Date()
) async throws -> Bool {
    // Preview is a staff-only "open": course staff see and use it exactly like an
    // open assignment, while students are held out as if it were closed. For
    // .open / .closed the stored visibility applies to everyone. Staff testing a
    // preview also bypass the future-open-date gate — see `submissionGate`.
    let gate = assignment.visibility.submissionGate(isStaff: user.isInstructor)
    let baseline = assignment.dueAt
    let extensionDueAt = try await studentExtensionDueAt(for: assignment, user: user, on: db)
    return isAssignmentOpenForUser(
        isOpen: gate.treatAsOpen,
        overrideActive: assignmentDeadlineOverrideIsActive(assignment),
        baselineDueAt: baseline,
        effectiveDueAt: laterDeadline(baseline: baseline, extensionDueAt: extensionDueAt),
        hasActiveExtension: studentHasActiveExtension(extensionDueAt: extensionDueAt, now: now),
        startsAt: gate.honorsStartDate ? assignment.startsAt : nil,
        now: now
    )
}

/// The deadline that gates release-tier *result visibility* for `user` viewing
/// `assignment`'s results: the effective (extension-aware) deadline, or nil when
/// there is no assignment or no deadline at all (release then visible
/// immediately).  A non-instructor may only view their own submission, so the
/// viewer is the submission owner and their extension is the right one to honour;
/// instructors see every tier regardless, so the value is unused for them.
func releaseVisibilityDeadline(
    for assignment: APIAssignment?,
    user: APIUser,
    on db: Database
) async throws -> Date? {
    guard let assignment else { return nil }
    return try await effectiveDueAt(for: assignment, user: user, on: db)
}

@discardableResult
func closeAssignmentIfExpired(
    _ assignment: APIAssignment,
    on db: Database,
    logger: Logger,
    now: Date = Date()
) async throws -> Bool {
    guard assignment.visibility == .open else { return false }
    guard assignmentDeadlineHasPassed(assignment, now: now) else { return false }
    guard !assignmentDeadlineOverrideIsActive(assignment) else { return false }

    // The assignment-wide visibility closes at the deadline even when some
    // students hold an active extension.  Per-student access after the close is
    // handled downstream, not by keeping the whole assignment open: the
    // submission gate (`isAssignmentOpenForUser`) treats a close *at/after* the
    // deadline as the automatic sweep and keeps submitting open for a student
    // whose `effectiveDueAt` is still in the future, and the student dashboard
    // re-includes setups where the viewer holds an active extension.  Leaving
    // the assignment-wide flag `.open` instead would make it read as "open" to
    // everyone (instructor dashboard + every student's list) long past the
    // deadline — the assignment would appear never to close whenever any
    // accommodation extension exists.
    assignment.visibility = .closed
    try await assignment.save(on: db)
    logger.info("Auto-closed assignment '\(assignment.title)' (\(assignment.publicID)) at deadline")
    return true
}

@discardableResult
func closeExpiredAssignments(
    on db: Database,
    logger: Logger,
    now: Date = Date()
) async throws -> Int {
    let assignments = try await APIAssignment.query(on: db)
        .filter(\.$visibilityRaw == AssignmentVisibility.open.rawValue)
        .group(.or) { group in
            group.filter(\.$deadlineOverrideActive == nil)
            group.filter(\.$deadlineOverrideActive == false)
        }
        .filter(\.$dueAt <= now)
        .all()

    var closedCount = 0
    for assignment in assignments
    where try await closeAssignmentIfExpired(assignment, on: db, logger: logger, now: now) {
        closedCount += 1
    }
    return closedCount
}

/// Auto-opens a single scheduled assignment once its open date has arrived —
/// the mirror image of `closeAssignmentIfExpired`.  Returns true if it flipped
/// `isOpen` to true.
///
/// The open date is *consumed* on success (`startsAt` set to nil) so a later
/// manual close (or the deadline sweep) can't be undone by a subsequent open
/// sweep.  Opening is suppressed when runner validation has not passed (mirrors
/// the manual-open guard) and when the due date has already passed (the window
/// is entirely in the past — opening would only be reversed by the close sweep).
@discardableResult
func openScheduledAssignment(
    _ assignment: APIAssignment,
    on db: Database,
    logger: Logger,
    now: Date = Date()
) async throws -> Bool {
    // Both `.closed` and `.preview` auto-open on their schedule. An open date
    // on a `.preview` assignment is the intended staff workflow: test in the
    // staff-only state now, and the sweep publishes to students when the open
    // date arrives (the same semantics `submissionGate` documents for why staff
    // bypass the start-date gate). Only `.open` is excluded — its open date has
    // already been consumed.
    guard assignment.visibility == .closed || assignment.visibility == .preview else { return false }
    guard let startsAt = assignment.startsAt, startsAt <= now else { return false }
    guard assignment.validationStatus == nil || assignment.validationStatus == "passed" else { return false }
    if let dueAt = assignment.dueAt, dueAt <= now { return false }

    assignment.visibility = .open
    assignment.startsAt = nil
    try await assignment.save(on: db)
    logger.info("Auto-opened assignment '\(assignment.title)' (\(assignment.publicID)) at its open date")
    return true
}

@discardableResult
func openScheduledAssignments(
    on db: Database,
    logger: Logger,
    now: Date = Date()
) async throws -> Int {
    let assignments = try await APIAssignment.query(on: db)
        .filter(
            \.$visibilityRaw
                ~~ [AssignmentVisibility.closed.rawValue, AssignmentVisibility.preview.rawValue]
        )
        .filter(\.$startsAt <= now)
        .all()

    var openedCount = 0
    for assignment in assignments
    where try await openScheduledAssignment(assignment, on: db, logger: logger, now: now) {
        openedCount += 1
    }
    return openedCount
}

func requireOpenStudentAssignment(
    for testSetupID: String,
    user: APIUser,
    on req: Request,
    now: Date = Date()
) async throws -> APIAssignment? {
    guard
        let assignment = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == testSetupID)
            .first()
    else {
        return nil
    }

    // Enforce course enrollment before any open/closed check.  Without this,
    // a student in course A who learns a testSetupID belonging to course B
    // (UUIDs are exposed in submission URLs, shared instructor pages, and
    // vanity-URL resolutions) can submit to that assignment and pollute
    // foreign instructors' queues.  Instructors and admins bypass via
    // `requireCourseEnrollment`'s own short-circuit.
    try await requireCourseEnrollment(caller: user, courseID: assignment.courseID, db: req.db)

    _ = try await closeAssignmentIfExpired(assignment, on: req.db, logger: req.logger, now: now)

    // Preview is open for course staff and closed for students — handled
    // uniformly by isAssignmentEffectivelyOpen, so staff use it via the normal
    // open path (bundled solution/tests, normal submission) with no special case.
    let open = try await isAssignmentEffectivelyOpen(assignment, for: user, on: req.db, now: now)
    guard open else {
        throw AssignmentSubmissionGateError.closed
    }
    return assignment
}

/// Sweep every minute so scheduled opens/closes land close to their times.
private let assignmentDeadlineSweepInterval: TimeInterval = 60

struct AssignmentDeadlineMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

extension Application {
    var assignmentDeadlineMonitor: PeriodicSweepMonitor {
        get {
            if let existing = storage[AssignmentDeadlineMonitorKey.self] { return existing }
            let created = PeriodicSweepMonitor(
                name: "Assignment deadline",
                interval: assignmentDeadlineSweepInterval,
                minimumInterval: 1,
                runImmediately: true
            ) { application in
                _ = try await openScheduledAssignments(
                    on: application.db,
                    logger: application.logger
                )
                _ = try await closeExpiredAssignments(
                    on: application.db,
                    logger: application.logger
                )
            }
            storage[AssignmentDeadlineMonitorKey.self] = created
            return created
        }
        set {
            storage[AssignmentDeadlineMonitorKey.self] = newValue
        }
    }
}
