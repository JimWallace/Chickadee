// APIServer/Helpers/ClassAchievements.swift
//
// Logic for awarding class-wide achievement badges when a 100% result arrives.
// Called from ResultRoutes after the result is persisted.

import Core
import Fluent
import Foundation

/// Awards class-wide badges for a 100%-grade submission.
/// Safe to call multiple times for the same submission (idempotent via unique constraint).
///
/// Class-wide badges are class-LEVEL recognitions and only meaningful for
/// enrolled students.  Admin/instructor test submissions used to lock in
/// the immutable Trailblazer badge before any real student got to attempt
/// the assignment (v0.4.127 fix).  This guard runs at the helper entry so
/// every call site is protected — including future ones.  Student-ness is
/// per-course now (#417 Slice G2): the submitter must hold a `.student`
/// enrollment in the setup's own course, not a retired global role.
func awardClassBadgesFor100Percent(
    testSetupID: String,
    userID: UUID,
    submissionID: String,
    executionTimeMs: Int,
    attemptNumber: Int,
    disabled: Set<String> = [],
    on db: Database
) async throws {
    guard let setup = try await APITestSetup.find(testSetupID, on: db),
        try await courseRole(of: userID, inCourse: setup.courseID, db: db) == .student
    else { return }

    // The class records to award — the manifest's authored ones (or the registry
    // default), minus disabled.  Each is awarded by its dimension; firstToSubmit
    // (Pathfinder) is awarded at submission time, not on reaching 100%.
    for record in BuiltInAchievements.classRecordsForAward(in: setup, disabled: disabled) {
        switch record.recordDimension {
        case .firstToSolve:
            try await awardImmutableBadge(
                achievementID: record.id,
                testSetupID: testSetupID, userID: userID, submissionID: submissionID, on: db)
        case .fastest:
            try await updateRecordBadge(
                achievementID: record.id,
                testSetupID: testSetupID, userID: userID, submissionID: submissionID,
                newValue: Double(executionTimeMs), on: db)
        case .shortest:
            try await updateRecordBadge(
                achievementID: record.id,
                testSetupID: testSetupID, userID: userID, submissionID: submissionID,
                newValue: Double(attemptNumber), on: db)
        case .firstToSubmit, .none:
            continue
        }
    }
}

/// Inserts the badge record only if no holder exists yet (first-to wins).
private func awardImmutableBadge(
    achievementID: String,
    testSetupID: String,
    userID: UUID,
    submissionID: String,
    on db: Database
) async throws {
    let existing = try await APIClassAchievement.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$achievementID == achievementID)
        .first()
    guard existing == nil else { return }
    let badge = APIClassAchievement(
        testSetupID: testSetupID, achievementID: achievementID,
        userID: userID, submissionID: submissionID)
    // Ignore conflict errors: two simultaneous 100% results, first insert wins.
    try? await badge.save(on: db)
}

/// Inserts the badge if none exists, or updates it when the new metric is strictly better
/// (lower value wins — both speed in ms and attempt count are lower-is-better).
/// In case of a tie the existing holder keeps the record (first achiever wins ties).
private func updateRecordBadge(
    achievementID: String,
    testSetupID: String,
    userID: UUID,
    submissionID: String,
    newValue: Double,
    on db: Database
) async throws {
    let existing = try await APIClassAchievement.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$achievementID == achievementID)
        .first()
    if let record = existing {
        guard let current = record.metricValue, newValue < current else { return }
        record.userID = userID
        record.submissionID = submissionID
        record.metricValue = newValue
        try await record.update(on: db)
    } else {
        let badge = APIClassAchievement(
            testSetupID: testSetupID, achievementID: achievementID,
            userID: userID, submissionID: submissionID, metricValue: newValue)
        try? await badge.save(on: db)
    }
}
