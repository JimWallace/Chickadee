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

func isAssignmentEffectivelyOpen(_ assignment: APIAssignment, now: Date = Date()) -> Bool {
    guard assignment.isOpen else { return false }
    guard assignmentDeadlineHasPassed(assignment, now: now) else { return true }
    return assignmentDeadlineOverrideIsActive(assignment)
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

/// Per-user variant of `isAssignmentEffectivelyOpen`.  An active extension
/// keeps submission open for one student even after the assignment-wide
/// deadline has passed.  The assignment's `isOpen` flag is still respected
/// — if an instructor manually closed an assignment, an extension does not
/// reopen it.
func isAssignmentEffectivelyOpen(
    _ assignment: APIAssignment,
    for user: APIUser,
    on db: Database,
    now: Date = Date()
) async throws -> Bool {
    guard assignment.isOpen else { return false }
    if !assignmentDeadlineHasPassed(assignment, now: now) { return true }
    if assignmentDeadlineOverrideIsActive(assignment) { return true }
    guard let effective = try await effectiveDueAt(for: assignment, user: user, on: db) else {
        return false
    }
    return now < effective
}

@discardableResult
func closeAssignmentIfExpired(
    _ assignment: APIAssignment,
    on db: Database,
    logger: Logger,
    now: Date = Date()
) async throws -> Bool {
    guard assignment.isOpen else { return false }
    guard assignmentDeadlineHasPassed(assignment, now: now) else { return false }
    guard !assignmentDeadlineOverrideIsActive(assignment) else { return false }

    assignment.isOpen = false
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
        .filter(\.$isOpen == true)
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
    let open = try await isAssignmentEffectivelyOpen(assignment, for: user, on: req.db, now: now)
    guard open else {
        throw AssignmentSubmissionGateError.closed
    }
    return assignment
}

final class AssignmentDeadlineMonitor: @unchecked Sendable {
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
