// APIServer/LTI/LTIGradeSyncSweep.swift
//
// Sends queued grades to the LMS through AGS (docs/lti-1-3.md "Grades through
// AGS"). It runs beside the Valence sweep and never touches that sweep's rows:
// a course uses one transport or the other.
//
// For each row past the debounce window it computes the student's current
// best grade with the same `bestGradeForStudent` the Valence push uses (so an
// override, best-of and a class-goal bonus mean the same thing on both
// transports), finds or creates the assignment's line item by `resourceId` =
// the assignment's public ID, and posts a score. A student with no grade left
// whose score the LMS has taken gets a clearing score.
//
// A failure the next sweep can fix (a network error, 5xx, 429, an expired
// token, a deleted line item) keeps the row pending. Any other failure
// records its reason and waits for a person: a new push, "Push all", or,
// when the student had never opened Chickadee from the LMS, their first
// launch.

import Fluent
import Foundation
import Vapor

struct LTIGradeSyncSweep {
    /// How long a row stays pending before the sweep sends it, so a burst of
    /// submissions sends one score. The same default as the Valence sweep.
    static let debounce: TimeInterval = 90
    static let interval: TimeInterval = 60

    static let notLaunchedMessage = "The student has not opened Chickadee from the LMS yet."
    static let noLineItemsMessage = "The LMS has not sent a grade service URL for this course."
    static let noTotalMessage = "The assignment has no point total to send."
    static let noGradeMessage = "Chickadee could not compute the grade."
    static let unreachableMessage = "Chickadee could not reach the LMS."

    let db: any Database
    let logger: Logger
    let client: LTIServiceClient
    let keys: @Sendable () async throws -> LTIToolKeyAuthority

    /// Sends every row pending since before `now - debounce` (every pending
    /// row when `bypassDebounce`). Returns the number of rows it finished.
    @discardableResult
    func run(now: Date = Date(), bypassDebounce: Bool = false) async throws -> Int {
        let cutoff = bypassDebounce ? Date.distantFuture : now.addingTimeInterval(-Self.debounce)
        let rows = try await APILTIGradeSync.query(on: db)
            .filter(\.$pending == true)
            .filter(\.$pendingSince <= cutoff)
            .all()
        guard !rows.isEmpty else { return 0 }

        // One lookup per assignment and course, shared by the sweep's rows, so
        // a line item found for one student is reused for the next.
        var assignments: [String: APIAssignment] = [:]
        var courses: [UUID: APICourse] = [:]
        var platforms: [UUID: APILTIPlatform] = [:]
        var finished = 0

        for row in rows {
            if assignments[row.testSetupID] == nil {
                assignments[row.testSetupID] = try await assignmentByTestSetupID(row.testSetupID, on: db)
            }
            guard let assignment = assignments[row.testSetupID] else {
                // The assignment is gone: nothing to send, ever.
                try await row.delete(on: db)
                finished += 1
                continue
            }
            if courses[assignment.courseID] == nil {
                courses[assignment.courseID] = try await APICourse.find(assignment.courseID, on: db)
            }
            guard let course = courses[assignment.courseID], course.usesLTIGrades,
                let platformID = course.ltiPlatformID
            else {
                // The course went back to Valence: drop the push.
                row.pending = false
                try await row.save(on: db)
                finished += 1
                continue
            }
            if platforms[platformID] == nil {
                platforms[platformID] = try await APILTIPlatform.find(platformID, on: db)
            }
            // A disabled platform keeps its rows waiting until it is enabled.
            guard let platform = platforms[platformID], platform.enabled else { continue }

            do {
                try await send(row, assignment: assignment, course: course, platform: platform, now: now)
                row.pending = false
                row.error = nil
            } catch let failure as Failure {
                row.pending = false
                row.error = failure.message
            } catch {
                let retryable = Self.isRetryable(error)
                row.pending = retryable
                row.error = Self.reason(for: error)
                logger.warning(
                    "LTI grade sync \(retryable ? "transient" : "terminal") failure: \(error)",
                    metadata: ["test_setup_id": .string(row.testSetupID)])
            }
            try await row.save(on: db)
            finished += 1
        }
        return finished
    }

    /// A reason the sweep will not send this row until something changes.
    private struct Failure: Error {
        let message: String
    }

    private func send(
        _ row: APILTIGradeSync, assignment: APIAssignment, course: APICourse, platform: APILTIPlatform, now: Date
    ) async throws {
        guard let lineItemsURL = course.ltiLineItemsURL else { throw Failure(message: Self.noLineItemsMessage) }
        guard let platformID = platform.id,
            let identity = try await APILTIIdentity.query(on: db)
                .filter(\.$platformID == platformID)
                .filter(\.$userID == row.userID)
                .first()
        else { throw Failure(message: Self.notLaunchedMessage) }

        let target = LTIServiceClient.Platform(id: platformID, registration: platform)
        let keys = try await keys()

        guard let grade = try await bestGradeForStudent(userID: row.userID, testSetupID: row.testSetupID, db: db)
        else {
            // No grade. Clear the LMS only when it holds one Chickadee sent.
            guard row.syncedAt != nil, let lineItem = assignment.ltiLineItemURL else { return }
            try await post(
                .cleared(userID: identity.subject, at: now), to: lineItem, assignment: assignment,
                platform: target, keys: keys)
            row.syncedAt = nil
            return
        }
        guard let total = grade.total, total > 0 else { throw Failure(message: Self.noTotalMessage) }

        let lineItem: String
        if let known = assignment.ltiLineItemURL {
            lineItem = known
        } else {
            lineItem = try await client.lineItemURL(
                resourceID: assignment.publicID, label: assignment.title, scoreMaximum: total,
                lineItemsURL: lineItemsURL, platform: target, keys: keys)
            assignment.ltiLineItemURL = lineItem
            try await assignment.save(on: db)
        }
        try await post(
            .graded(userID: identity.subject, points: grade.points, maximum: total, at: now), to: lineItem,
            assignment: assignment, platform: target, keys: keys)
        row.syncedAt = now
    }

    private func post(
        _ score: LTIScore, to lineItem: String, assignment: APIAssignment, platform: LTIServiceClient.Platform,
        keys: LTIToolKeyAuthority
    ) async throws {
        do {
            try await client.postScore(score, lineItemURL: lineItem, platform: platform, keys: keys)
        } catch LTIServiceError.lineItemGone {
            // Forget the deleted line item; the retry finds or creates a new one.
            assignment.ltiLineItemURL = nil
            try await assignment.save(on: db)
            throw LTIServiceError.lineItemGone
        }
    }

    /// The one sentence the instructor page shows for a failure. The full
    /// error goes to the log only, so the page never shows raw error text.
    static func reason(for error: any Error) -> String {
        if let agsError = error as? LTIServiceError { return agsError.description }
        if error is BrightSpaceSyncError { return noGradeMessage }
        return unreachableMessage
    }

    /// AGS errors say for themselves. `bestGradeForStudent` throws a
    /// `BrightSpaceSyncError` when a grade cannot be computed, which no retry
    /// fixes. Anything else is a transport error, worth another try.
    static func isRetryable(_ error: any Error) -> Bool {
        if let agsError = error as? LTIServiceError { return agsError.isRetryable }
        if error is BrightSpaceSyncError { return false }
        return true
    }
}

// MARK: - Application wiring

private struct LTIServiceClientKey: StorageKey {
    typealias Value = LTIServiceClient
}

private struct LTIGradeSyncMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

extension Application {
    /// The AGS HTTP client. Tests replace it with one whose `send` answers
    /// for the LMS.
    var ltiServiceClient: LTIServiceClient {
        get {
            lazyStored(LTIServiceClientKey.self) {
                let client = self.client
                return LTIServiceClient { request in try await client.send(request) }
            }
        }
        set { storage[LTIServiceClientKey.self] = newValue }
    }

    /// A sweep over this application's database, client and tool key.
    var ltiGradeSyncSweep: LTIGradeSyncSweep {
        LTIGradeSyncSweep(
            db: db, logger: logger, client: ltiServiceClient,
            keys: { [self] in try await self.ltiToolKeyAuthority() })
    }

    /// The AGS sweep. It runs on every deployment and finds an empty queue
    /// unless a course has chosen AGS.
    var ltiGradeSyncMonitor: PeriodicSweepMonitor {
        lazyStored(LTIGradeSyncMonitorKey.self) {
            PeriodicSweepMonitor(
                name: "LTI grade sync", interval: LTIGradeSyncSweep.interval, runImmediately: false
            ) { application in
                let sent = try await application.ltiGradeSyncSweep.run()
                if sent > 0 { application.logger.info("LTI grade sync: finished \(sent) row(s)") }
            }
        }
    }
}
