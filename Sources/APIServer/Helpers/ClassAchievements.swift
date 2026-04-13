// APIServer/Helpers/ClassAchievements.swift
//
// Logic for awarding class-wide achievement badges when a 100% result arrives.
// Called from ResultRoutes after the result is persisted.

import Fluent
import Foundation

/// Awards class-wide badges for a 100%-grade submission.
/// Safe to call multiple times for the same submission (idempotent via unique constraint).
func awardClassBadgesFor100Percent(
    testSetupID: String,
    userID: UUID,
    submissionID: String,
    executionTimeMs: Int,
    attemptNumber: Int,
    on db: Database
) async throws {
    async let _trail = awardImmutableBadge(
        achievementID: "trailblazer",
        testSetupID: testSetupID, userID: userID, submissionID: submissionID, on: db)
    async let _speed = updateRecordBadge(
        achievementID: "speed_champion",
        testSetupID: testSetupID, userID: userID, submissionID: submissionID,
        newValue: Double(executionTimeMs), on: db)
    async let _mini  = updateRecordBadge(
        achievementID: "minimalist",
        testSetupID: testSetupID, userID: userID, submissionID: submissionID,
        newValue: Double(attemptNumber), on: db)
    _ = try await (_trail, _speed, _mini)
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
        .filter(\.$testSetupID  == testSetupID)
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
        .filter(\.$testSetupID  == testSetupID)
        .filter(\.$achievementID == achievementID)
        .first()
    if let record = existing {
        guard let current = record.metricValue, newValue < current else { return }
        record.userID       = userID
        record.submissionID = submissionID
        record.metricValue  = newValue
        try await record.update(on: db)
    } else {
        let badge = APIClassAchievement(
            testSetupID: testSetupID, achievementID: achievementID,
            userID: userID, submissionID: submissionID, metricValue: newValue)
        try? await badge.save(on: db)
    }
}
