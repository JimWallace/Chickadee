// APIServer/Services/BrightSpaceGradeSyncService.swift
//
// Debounced BrightSpace grade-sync sweep.
//
// When a worker result is saved, ResultRoutes sets brightspace_sync_pending = true
// on the APIResult row.  This service polls every 60 seconds and pushes the best
// grade for each (student, assignment) pair whose pending flag has been set for
// longer than the configured debounce window (default 90 s).
//
// If BrightSpace is unreachable the error is recorded on the result row and the
// push retries on the next sweep — no work is lost.

import Vapor
import Fluent
import Foundation

// MARK: - Pure sweep function

/// Sweeps for pending grade pushes and executes them.
/// Returns the number of results processed (success or failure).
@discardableResult
func sweepBrightSpaceGradeSync(
    on db: Database,
    client: BrightSpaceAPIClient,
    config: BrightSpaceSyncConfig,
    logger: Logger,
    application: Application,
    now: Date = Date()
) async throws -> Int {
    let cutoff = now.addingTimeInterval(-config.debounceSecs)

    // All results that are past the debounce window.
    let pending = try await APIResult.query(on: db)
        .filter(\.$brightspaceSyncPending == true)
        .filter(\.$brightspacePendingSince <= cutoff)
        .all()

    guard !pending.isEmpty else { return 0 }

    var processed = 0

    for result in pending {
        do {
            try await pushGradeForResult(result, db: db, client: client, logger: logger, application: application)
            processed += 1
        } catch {
            result.brightspaceSyncPending = false
            result.brightspaceSyncedAt = nil
            result.brightspaceSyncError = error.localizedDescription
            try? await result.save(on: db)
            logger.warning("BrightSpace grade sync failed for result \(result.id ?? "?"): \(error)")
        }
    }
    return processed
}

private func pushGradeForResult(
    _ result: APIResult,
    db: Database,
    client: BrightSpaceAPIClient,
    logger: Logger,
    application: Application
) async throws {
    // Resolve submission → userID + testSetupID.
    guard let submission = try await APISubmission.find(result.submissionID, on: db) else {
        // Orphaned result — just clear the flag.
        result.brightspaceSyncPending = false
        try await result.save(on: db)
        return
    }

    // Skip validation submissions.
    guard submission.kind == APISubmission.Kind.student,
          let userID = submission.userID
    else {
        result.brightspaceSyncPending = false
        try await result.save(on: db)
        return
    }

    let testSetupID = submission.testSetupID

    // Find the assignment for this test setup.
    guard let assignment = try await APIAssignment.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .first(),
        let gradeObjectID = assignment.brightspaceGradeObjectID,
        !gradeObjectID.isEmpty
    else {
        // No BrightSpace grade item configured — no-op.
        result.brightspaceSyncPending = false
        try await result.save(on: db)
        return
    }

    // Find the course's org unit ID.
    guard let course = try await APICourse.find(assignment.courseID, on: db),
          let orgUnitID = course.brightspaceOrgUnitID,
          !orgUnitID.isEmpty
    else {
        result.brightspaceSyncPending = false
        try await result.save(on: db)
        return
    }

    // Compute best grade for this student across all results for this test setup.
    let studentSubmissions = try await APISubmission.query(on: db)
        .filter(\.$userID == userID)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$kind == APISubmission.Kind.student)
        .all()

    let submissionIDs = studentSubmissions.compactMap(\.id)
    guard !submissionIDs.isEmpty else {
        result.brightspaceSyncPending = false
        try await result.save(on: db)
        return
    }

    let allResults = try await APIResult.query(on: db)
        .filter(\.$submissionID ~~ submissionIDs)
        .all()

    // Prefer worker results; fall back to browser results for best-grade computation.
    let workerResults = allResults.filter { $0.source != "browser" }
    let resultsForGrade = workerResults.isEmpty ? allResults : workerResults

    let bestPoints = resultsForGrade
        .compactMap { gradePointsFromCollectionJSON($0.collectionJSON) }
        .max()

    guard let points = bestPoints else {
        throw BrightSpaceSyncError.missingPoints
    }

    // Resolve D2L user ID (cached on APIUser, looked up on first sync).
    let bsUserID = try await resolvedBrightSpaceUserID(
        for: userID,
        db: db,
        client: client,
        application: application
    )
    guard let bsUserID else {
        // No BrightSpace account for this student — skip silently.
        result.brightspaceSyncPending = false
        result.brightspaceSyncError = "Student has no BrightSpace account (orgDefinedId not found)"
        try await result.save(on: db)
        return
    }

    // Push the grade.
    try await client.pushGrade(
        orgUnitID: orgUnitID,
        gradeObjectID: gradeObjectID,
        bsUserID: bsUserID,
        earnedPoints: points,
        on: application
    )

    result.brightspaceSyncPending = false
    result.brightspacePendingSince = nil
    result.brightspaceSyncedAt = Date()
    result.brightspaceSyncError = nil
    try await result.save(on: db)

    logger.info("BrightSpace grade synced: user \(userID) assignment '\(assignment.title)' → \(points) pts")
}

/// Returns the cached D2L user ID for `userID`, looking it up via studentID if not yet cached.
private func resolvedBrightSpaceUserID(
    for userID: UUID,
    db: Database,
    client: BrightSpaceAPIClient,
    application: Application
) async throws -> String? {
    guard let user = try await APIUser.find(userID, on: db) else { return nil }

    if let cached = user.brightspaceUserID, !cached.isEmpty {
        return cached
    }

    // Look up by studentID (= BrightSpace OrgDefinedId).
    guard let orgDefinedId = user.studentID, !orgDefinedId.isEmpty else {
        return nil
    }

    let bsUserID = try await client.lookupUserID(orgDefinedId: orgDefinedId, on: application)

    if let bsUserID {
        user.brightspaceUserID = bsUserID
        try await user.save(on: db)
    }
    return bsUserID
}

// MARK: - Monitor

final class BrightSpaceGradeSyncMonitor: @unchecked Sendable {
    private var task: Task<Void, Never>?
    private let sweepIntervalNanoseconds: UInt64 = 60 * 1_000_000_000

    func start(application: Application) {
        guard task == nil,
              let client = application.brightSpaceClient,
              let config = application.brightSpaceSyncConfig
        else { return }

        task = Task {
            while !Task.isCancelled {
                do {
                    let n = try await sweepBrightSpaceGradeSync(
                        on: application.db,
                        client: client,
                        config: config,
                        logger: application.logger,
                        application: application
                    )
                    if n > 0 {
                        application.logger.info("BrightSpace grade sync: pushed \(n) grade(s)")
                    }
                } catch {
                    application.logger.error("BrightSpace grade sync sweep failed: \(error.localizedDescription)")
                }
                do {
                    try await Task.sleep(nanoseconds: sweepIntervalNanoseconds)
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

// MARK: - Lifecycle handler

struct BrightSpaceGradeSyncMonitorKey: StorageKey {
    typealias Value = BrightSpaceGradeSyncMonitor
}

struct BrightSpaceGradeSyncLifecycleHandler: LifecycleHandler {
    func didBoot(_ application: Application) throws {
        application.brightSpaceGradeSyncMonitor.start(application: application)
    }

    func shutdown(_ application: Application) {
        application.brightSpaceGradeSyncMonitor.stop()
    }
}

extension Application {
    var brightSpaceGradeSyncMonitor: BrightSpaceGradeSyncMonitor {
        get {
            if let existing = storage[BrightSpaceGradeSyncMonitorKey.self] { return existing }
            let created = BrightSpaceGradeSyncMonitor()
            storage[BrightSpaceGradeSyncMonitorKey.self] = created
            return created
        }
        set { storage[BrightSpaceGradeSyncMonitorKey.self] = newValue }
    }

    var brightSpaceSyncConfig: BrightSpaceSyncConfig? {
        get { storage[BrightSpaceSyncConfigKey.self] }
        set { storage[BrightSpaceSyncConfigKey.self] = newValue }
    }
}

struct BrightSpaceSyncConfigKey: StorageKey {
    typealias Value = BrightSpaceSyncConfig
}
