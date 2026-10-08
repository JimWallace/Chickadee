// APIServer/Services/GradePushRequest.swift
//
// One request to push a changed grade to the LMS, for every place that changes
// a grade (#2259, item 2).
//
// Chickadee pushes grades through two integrations: BrightSpace Valence and LTI
// AGS. Each trigger used to call both by hand: a new result, a grade override
// set or cleared, and a class-goal bonus that froze at the deadline. The pair
// has gone wrong before: the browser result path did not set the BrightSpace
// flag, so notebook labs never pushed to LEARN on their own. A trigger that
// calls one integration and forgets the other leaves a wrong grade in the
// institution's system of record, and nothing reports it. A new trigger calls
// `requestGradePush` once. `GradePushCoverageTests` keeps the per-integration
// calls in this file.
//
// Each integration keeps its own queue, sweep and data, and each call below is
// a no-op for a course that does not use that integration.

import Fluent
import Foundation
import Vapor

/// The grades a change touches.
enum GradePushScope {
    /// A newly built result. The BrightSpace flag is set in memory, so the
    /// caller must save the row afterwards; both ingest paths do, so the flag
    /// rides on the same INSERT.
    case result(APIResult, application: Application)
    /// One student's grade after an override changed: `override` is the row
    /// that was set, or nil when it was cleared.
    case student(UUID, override: APIGradeOverride?)
    /// Every student's grade on the assignment, after its class-goal bonus
    /// froze at the deadline.
    case allStudents(APIAssignment, logger: Logger)
}

/// Asks both LMS integrations to push the grades in `scope` for `testSetupID`.
func requestGradePush(_ scope: GradePushScope, testSetupID: String, on db: any Database) async throws {
    switch scope {
    case .result(let result, let application):
        try await flagResultForBrightSpaceSync(
            result, testSetupID: testSetupID, application: application, on: db)
        try await LTIGradeSyncQueue.queue(submissionID: result.submissionID, testSetupID: testSetupID, on: db)
    case .student(let studentUserID, let override):
        try await LTIGradeSyncQueue.queue(userIDs: [studentUserID], testSetupID: testSetupID, on: db)
        try await flagStudentForBrightSpaceSync(
            override: override, testSetupID: testSetupID, studentUserID: studentUserID, on: db)
    case .allStudents(let assignment, let logger):
        try await LTIGradeSyncQueue.queueAllStudents(testSetupID: testSetupID, on: db)
        try await requeueFrozenClassGoalBonusPushes(
            assignment: assignment, testSetupID: testSetupID, on: db, logger: logger)
    }
}
