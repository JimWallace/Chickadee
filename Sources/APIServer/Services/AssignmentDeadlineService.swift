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
/// The assignment-wide `isOpen` flag is flipped to false two different ways: an
/// instructor closing it manually, or the automatic deadline sweep
/// (`closeExpiredAssignments`).  We can only tell them apart by timing — a close
/// while the deadline is still in the future is a deliberate manual close, and
/// an extension does not reopen it; a close at/after the deadline is the
/// automatic sweep, so an active per-student extension (a later `effectiveDueAt`)
/// keeps submission open for that one student.
func isAssignmentOpenForUser(
    isOpen: Bool,
    overrideActive: Bool,
    baselineDueAt: Date?,
    effectiveDueAt: Date?,
    startsAt: Date? = nil,
    now: Date = Date()
) -> Bool {
    // Front gate: a future open date holds the assignment closed for
    // everyone, regardless of `isOpen` or any deadline/extension state.
    if let startsAt, now < startsAt { return false }
    let deadlinePassed = baselineDueAt.map { $0 <= now } ?? false
    if isOpen {
        if !deadlinePassed { return true }
        if overrideActive { return true }
    } else if !deadlinePassed {
        // Closed before the deadline — a deliberate manual close that an
        // extension must not reopen.
        return false
    }
    guard let effectiveDueAt else { return false }
    return now < effectiveDueAt
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
    let baseline = assignment.dueAt
    guard let assignmentID = assignment.id, let userID = user.id else {
        return baseline
    }
    guard
        let extensionRow = try await APIAssignmentExtension.query(on: db)
            .filter(\.$assignmentID == assignmentID)
            .filter(\.$userID == userID)
            .first()
    else {
        return baseline
    }
    if let baseline {
        return max(baseline, extensionRow.extendedDueAt)
    }
    return extensionRow.extendedDueAt
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
    // .open / .closed the stored visibility applies to everyone.
    let treatAsOpen: Bool
    switch assignment.visibility {
    case .open: treatAsOpen = true
    case .closed: treatAsOpen = false
    case .preview: treatAsOpen = user.isInstructor
    }
    let effective = try await effectiveDueAt(for: assignment, user: user, on: db)
    return isAssignmentOpenForUser(
        isOpen: treatAsOpen,
        overrideActive: assignmentDeadlineOverrideIsActive(assignment),
        baselineDueAt: assignment.dueAt,
        effectiveDueAt: effective,
        startsAt: assignment.startsAt,
        now: now
    )
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
    // Only a `.closed` assignment auto-opens on its schedule. A `.preview`
    // assignment is a deliberate staff-only beta state: it is published to
    // students manually after testing, never by the scheduled-open sweep.
    guard assignment.visibility == .closed else { return false }
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
        .filter(\.$visibilityRaw == AssignmentVisibility.closed.rawValue)
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

final class AssignmentDeadlineMonitor: @unchecked Sendable {
    // @unchecked Sendable: the only mutable state (`task`) is touched solely
    // from start()/stop() on the app lifecycle (didBoot/shutdown), never
    // concurrently.
    private var task: Task<Void, Never>?
    private let intervalNanoseconds: UInt64

    init(interval: TimeInterval = 60) {
        intervalNanoseconds = UInt64(max(interval, 1) * 1_000_000_000)
    }

    func start(application: Application) {
        guard task == nil else { return }
        task = Task {
            while !Task.isCancelled {
                do {
                    _ = try await openScheduledAssignments(
                        on: application.db,
                        logger: application.logger
                    )
                    _ = try await closeExpiredAssignments(
                        on: application.db,
                        logger: application.logger
                    )
                } catch {
                    application.logger.error("Assignment deadline sweep failed: \(error.localizedDescription)")
                }

                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    break
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

struct AssignmentDeadlineMonitorKey: StorageKey {
    typealias Value = AssignmentDeadlineMonitor
}

struct AssignmentDeadlineLifecycleHandler: LifecycleHandler {
    func didBoot(_ application: Application) throws {
        Task {
            do {
                _ = try await openScheduledAssignments(on: application.db, logger: application.logger)
                _ = try await closeExpiredAssignments(on: application.db, logger: application.logger)
            } catch {
                application.logger.error("Initial assignment deadline sweep failed: \(error.localizedDescription)")
            }
        }
        application.assignmentDeadlineMonitor.start(application: application)
    }

    func shutdown(_ application: Application) {
        application.assignmentDeadlineMonitor.stop()
    }
}

extension Application {
    var assignmentDeadlineMonitor: AssignmentDeadlineMonitor {
        get {
            if let existing = storage[AssignmentDeadlineMonitorKey.self] { return existing }
            let created = AssignmentDeadlineMonitor()
            storage[AssignmentDeadlineMonitorKey.self] = created
            return created
        }
        set {
            storage[AssignmentDeadlineMonitorKey.self] = newValue
        }
    }
}
