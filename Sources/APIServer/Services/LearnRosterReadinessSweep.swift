// APIServer/Services/LearnRosterReadinessSweep.swift
//
// Periodic roster-readiness sweep. For every course bound to a LEARN org unit,
// fetches the classlist once and classifies each enrolled student against it
// (reusing the pure `LearnRosterReconciler`), persisting the result on the
// `course_enrollments` row as `LearnSyncReadiness` — confirmed (matched, we can
// push their grade), unreachable (not on the classlist / no key to match), or
// left unconfirmed when the course has no connected identity to read the
// classlist with.
//
// This is a *signal* layer only: it never touches a grade. An unreachable
// student's grade still queues and is never lost; the status tells the
// instructor we can't deliver it yet (surfaced on the LEARN tab). It mirrors
// the on-demand Students-tab "Check against LEARN" but runs proactively and
// persists, so the instructor sees drift before term-end.

import Core
import Fluent
import Foundation
import Vapor

/// Outcome counts for one course's reconcile pass.
struct RosterReadinessOutcome: Sendable {
    var checked = 0
    var confirmed = 0
    var unreachable = 0
    /// Enrollment rows whose stored status actually changed this pass.
    var updated = 0
}

/// Reconciles one course's enrolled students against its LEARN classlist and
/// persists each enrollment's `LearnSyncReadiness`. The caller supplies the
/// already-resolved client (so the sweep and the manual "Reconcile now" route
/// share this core). Only `student`-role enrollments are classified — an
/// instructor/admin test account isn't a roster member and is never flagged.
@discardableResult
func reconcileCourseReadiness(
    course: APICourse,
    orgUnitID: String,
    client: any BrightSpaceGrading,
    on db: Database,
    application: Application
) async throws -> RosterReadinessOutcome {
    guard let courseID = course.id else { return RosterReadinessOutcome() }

    let classlist = try await client.fetchClasslist(orgUnitID: orgUnitID, on: application)
    let learnIdentities = LearnRosterReconciler.identitySet(from: classlist)

    let enrollments = try await APICourseEnrollment.query(on: db)
        .filter(\.$course.$id == courseID)
        .all()
    let studentEnrollments = enrollments.filter { $0.role == .student }
    guard !studentEnrollments.isEmpty else { return RosterReadinessOutcome() }

    let userIDs = studentEnrollments.map(\.userID)
    // `userIDs` already come from `.student`-role enrollments (#417 Slice G2),
    // so no global-role filter is needed — teaching staff are excluded upstream.
    let users = try await APIUser.query(on: db)
        .filter(\.$id ~~ userIDs)
        .all()
    var userByID: [UUID: APIUser] = [:]
    for user in users {
        if let id = user.id { userByID[id] = user }
    }

    let now = Date()
    var outcome = RosterReadinessOutcome()
    for enrollment in studentEnrollments {
        // A globally non-student account enrolled as a course student is skipped
        // — it isn't a graded roster member.
        guard let student = userByID[enrollment.userID] else { continue }
        outcome.checked += 1

        let studentID = student.studentID ?? ""
        let (readiness, detail) = readinessFor(
            studentID: studentID, username: student.username, learnIdentities: learnIdentities)
        switch readiness {
        case .confirmed: outcome.confirmed += 1
        case .unreachable: outcome.unreachable += 1
        case .unconfirmed: break
        }

        let changed =
            enrollment.learnSyncReadiness != readiness
            || enrollment.brightspaceSyncDetail != detail
        enrollment.learnSyncReadiness = readiness
        enrollment.brightspaceSyncDetail = detail
        enrollment.brightspaceCheckedAt = now
        try await enrollment.save(on: db)
        if changed { outcome.updated += 1 }
    }
    return outcome
}

/// Maps the pure reconciler's classification onto the persisted readiness +
/// a human-readable reason for the instructor.
private func readinessFor(
    studentID: String, username: String, learnIdentities: Set<String>
) -> (LearnSyncReadiness, String?) {
    switch LearnRosterReconciler.classify(
        candidateKeys: [studentID, username],
        hasIdentityKey: !studentID.isEmpty,
        learnIdentities: learnIdentities
    ) {
    case .onLearn:
        return (.confirmed, nil)
    case .notOnLearn:
        return (.unreachable, "Not on the LEARN classlist (dropped, or not enrolled in the D2L course).")
    case .unverifiable:
        return (
            .unreachable,
            "Couldn't match to LEARN — add a student/org-defined ID, or check the username matches LEARN."
        )
    }
}

/// Sweeps every BrightSpace-bound course's roster readiness. Returns the total
/// number of enrollment rows whose status changed across all courses. A course
/// with no connected sync identity (no key to read the classlist) is skipped,
/// leaving its students' statuses as-is — never wrongly flagged unreachable.
@discardableResult
func sweepLearnRosterReadiness(
    on db: Database,
    resolveClient: (APICourse) async throws -> (any BrightSpaceGrading)?,
    logger: Logger,
    application: Application
) async throws -> Int {
    // Only courses bound to a LEARN org unit can be reconciled.
    let courses = try await APICourse.query(on: db).all()
    var totalUpdated = 0
    for course in courses {
        guard let orgUnitID = course.brightspaceOrgUnitID, !orgUnitID.isEmpty else { continue }
        let client: (any BrightSpaceGrading)?
        do {
            client = try await resolveClient(course)
        } catch {
            logger.warning(
                "Roster readiness: client resolve failed for course \(course.id?.uuidString ?? "?"): \(error)")
            continue
        }
        guard let client else { continue }  // no identity connected yet — defer

        do {
            let outcome = try await reconcileCourseReadiness(
                course: course, orgUnitID: orgUnitID, client: client,
                on: db, application: application)
            totalUpdated += outcome.updated
            if outcome.updated > 0 {
                let line =
                    "Roster readiness for \(course.code): \(outcome.confirmed) confirmed, "
                    + "\(outcome.unreachable) unreachable (\(outcome.updated) changed)"
                logger.info("\(line)")
            }
        } catch {
            logger.warning("Roster readiness sweep failed for course \(course.code): \(error)")
        }
    }
    return totalUpdated
}

// MARK: - Monitor (reuses the shared PeriodicSweepMonitor scaffolding)

/// Roster-readiness sweep cadence: 10 minutes. Classlists change rarely, so a
/// slow cadence keeps D2L traffic low while still catching drift (a drop / late
/// add) within the term. The identity is resolved per course each cycle, so a
/// fresh connect takes effect without a restart.
private let learnRosterReadinessInterval: TimeInterval = 10 * 60

struct LearnRosterReadinessMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

extension Application {
    /// The roster-readiness periodic sweep, built on the shared
    /// `PeriodicSweepMonitor` (same scaffolding as the reapers). Registered via
    /// `PeriodicSweepLifecycleHandler` in `AppServices`, only when BrightSpace
    /// is configured. The sweep itself no-ops when credentials are absent.
    var learnRosterReadinessMonitor: PeriodicSweepMonitor {
        get {
            if let existing = storage[LearnRosterReadinessMonitorKey.self] { return existing }
            let created = PeriodicSweepMonitor(
                name: "LEARN roster readiness",
                interval: learnRosterReadinessInterval,
                runImmediately: false
            ) { application in
                guard application.brightSpaceAppCredentials != nil else { return }
                _ = try await sweepLearnRosterReadiness(
                    on: application.db,
                    resolveClient: { course in
                        try await application.brightSpaceClient(forCourse: course)
                    },
                    logger: application.logger,
                    application: application
                )
            }
            storage[LearnRosterReadinessMonitorKey.self] = created
            return created
        }
        set { storage[LearnRosterReadinessMonitorKey.self] = newValue }
    }
}
