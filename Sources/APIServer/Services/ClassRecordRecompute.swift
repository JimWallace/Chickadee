// APIServer/Services/ClassRecordRecompute.swift
//
// Recomputes the class records that a 100% result earns (first to solve,
// fastest, fewest attempts) from every student's current result (#2054, A12).
//
// The incremental award in `awardClassBadgesFor100Percent` only ever moves a
// record to a better result. A retest breaks that in two ways:
//
//   * A retest adds a new result row. When the holder's new result is worse
//     (below 100%, or slower), nothing took the record away.
//   * After a retest-all, first to solve went to whichever retest result was
//     ingested first, not to the student who submitted first.
//
// So a retest result recomputes each record from the submissions themselves.
// A submission counts by its LATEST result, because a retest re-grades it under
// the current suite. The grade of record keeps each submission's best row, so a
// student can keep a 100% grade and lose a record to a retest. That is the
// intended difference: a record says who holds it under the suite as it is now.
//
// First to solve also changes meaning on a recompute. The incremental award
// gives it to the first 100% result to ARRIVE; the recompute gives it to the
// earliest SUBMISSION whose latest result is 100%. After a retest the second is
// the fair answer, because a retest-all delivers results in no useful order.
//
// A latest result whose grade columns are nil does not count. Every creation
// path stamps them (`saveWithCollection`), so only a failed build, which has no
// points, leaves them empty in practice.
//
// Recomputes for one assignment run one at a time: `ClassRecordRecomputeQueue`.

import Core
import Fluent
import Foundation

/// The record dimensions this recompute owns. The others (first to submit, the
/// ranking metric, champion, tournament winner) are not earned by a 100% result.
private let recomputedDimensions: Set<RecordDimension> = [.firstToSolve, .fastest, .shortest]

/// One student submission whose latest result is a full mark.
private struct RecordCandidate {
    let userID: UUID
    let submissionID: String
    let submittedAt: Date
    let attemptNumber: Int
    let executionTimeMs: Int?
}

/// Recomputes the 100%-earned class records of `setup` from every student
/// submission's latest result. A record with no qualifying submission is
/// removed. Ties go to the earlier submission.
func recomputeClassRecords(setup: APITestSetup, on db: Database) async throws {
    guard let setupID = setup.id else { return }
    let records = BuiltInAchievements.classRecordsForAward(
        in: setup, disabled: BuiltInAchievements.disabled(in: setup)
    )
    .filter { record in record.recordDimension.map { recomputedDimensions.contains($0) } ?? false }
    guard !records.isEmpty else { return }

    let candidates = try await recordCandidates(
        setupID: setupID, courseID: setup.courseID,
        needsExecutionTime: records.contains { $0.recordDimension == .fastest },
        on: db)

    for record in records {
        let winner: RecordCandidate?
        let metric: Double?
        switch record.recordDimension {
        case .firstToSolve:
            winner = candidates.min(by: earlier)
            metric = nil
        case .fastest:
            winner = candidates.filter { $0.executionTimeMs != nil }.min { lhs, rhs in
                lhs.executionTimeMs == rhs.executionTimeMs
                    ? earlier(lhs, rhs) : (lhs.executionTimeMs ?? 0) < (rhs.executionTimeMs ?? 0)
            }
            metric = winner?.executionTimeMs.map(Double.init)
        case .shortest:
            winner = candidates.min { lhs, rhs in
                lhs.attemptNumber == rhs.attemptNumber
                    ? earlier(lhs, rhs) : lhs.attemptNumber < rhs.attemptNumber
            }
            metric = winner.map { Double($0.attemptNumber) }
        default:
            continue
        }
        try await storeRecordHolder(
            achievementID: record.id, testSetupID: setupID, winner: winner, metric: metric, on: db)
    }
}

/// True when `lhs` was submitted before `rhs`; the submission id breaks a tie,
/// so the answer never depends on query order.
private func earlier(_ lhs: RecordCandidate, _ rhs: RecordCandidate) -> Bool {
    lhs.submittedAt == rhs.submittedAt
        ? lhs.submissionID < rhs.submissionID : lhs.submittedAt < rhs.submittedAt
}

/// Every student submission of the setup whose latest result is a full mark.
/// Only a `.student` in the setup's own course counts, as in the incremental
/// award.
private func recordCandidates(
    setupID: String, courseID: UUID, needsExecutionTime: Bool, on db: Database
) async throws -> [RecordCandidate] {
    let students = Set(
        try await APICourseEnrollment.query(on: db)
            .filter(\.$course.$id == courseID)
            .all()
            .filter { $0.role == .student }
            .map(\.userID))
    let submissions = try await APISubmission.query(on: db)
        .filter(\.$testSetupID == setupID)
        .filter(\.$kind == APISubmission.Kind.student)
        .all()
        .filter { $0.userID.map(students.contains) ?? false }
    let resultsBySubmission = try await allResultsBySubmissionID(
        for: submissions.compactMap(\.id), on: db)

    // Newest first within each submission, so the first row is the latest.
    var latestFullMarks: [(submission: APISubmission, result: APIResult)] = []
    for submission in submissions {
        guard let id = submission.id, let latest = resultsBySubmission[id]?.first,
            let earned = latest.earnedPoints, let total = latest.totalPoints,
            GradePercent.of(earned: earned, total: total) == 100
        else { continue }
        latestFullMarks.append((submission, latest))
    }

    var executionTimes: [String: Int] = [:]
    if needsExecutionTime {
        let blobs = try await collectionJSONByResultID(
            for: latestFullMarks.compactMap { $0.result.id }, on: db)
        for (resultID, json) in blobs {
            executionTimes[resultID] = decodedCollection(from: json)?.executionTimeMs
        }
    }

    return latestFullMarks.compactMap { pair in
        guard let userID = pair.submission.userID, let submissionID = pair.submission.id else {
            return nil
        }
        return RecordCandidate(
            userID: userID,
            submissionID: submissionID,
            submittedAt: pair.submission.submittedAt ?? .distantFuture,
            attemptNumber: pair.submission.attemptNumber ?? 1,
            executionTimeMs: pair.result.id.flatMap { executionTimes[$0] })
    }
}

/// Makes `winner` the holder of the record, or removes the record when there is
/// no winner. Writes nothing when the holder is unchanged.
private func storeRecordHolder(
    achievementID: String,
    testSetupID: String,
    winner: RecordCandidate?,
    metric: Double?,
    on db: Database
) async throws {
    let existing = try await APIClassAchievement.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$achievementID == achievementID)
        .first()
    guard let winner else {
        try await existing?.delete(on: db)
        return
    }
    if let record = existing {
        guard
            record.userID != winner.userID || record.submissionID != winner.submissionID
                || record.metricValue != metric
        else { return }
        record.userID = winner.userID
        record.submissionID = winner.submissionID
        record.metricValue = metric
        try await record.update(on: db)
    } else {
        let badge = APIClassAchievement(
            testSetupID: testSetupID, achievementID: achievementID,
            userID: winner.userID, submissionID: winner.submissionID, metricValue: metric)
        try await badge.createIgnoringConflict(on: db)
    }
}
