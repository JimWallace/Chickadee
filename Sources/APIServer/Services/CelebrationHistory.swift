// APIServer/Services/CelebrationHistory.swift
//
// The earlier graded attempts a result-page celebration compares against
// (docs/result-celebration.md). It reads only the submitter's own student
// submissions on one assignment, when the page renders: never while a result
// is written.

import Core
import Fluent
import Foundation

/// A student's other graded attempts on the assignment of one submission.
struct CelebrationHistory: Equatable {
    /// No later attempt of the student's on this assignment has a result.
    let isLatest: Bool
    /// The percent of the latest earlier attempt that has a result.
    let previousPercent: Int?
    /// The highest percent of every earlier attempt that has a result.
    let bestPercent: Int?

    /// One graded attempt: its number and its autograded percent.
    struct Attempt: Equatable {
        let number: Int
        let percent: Int?
    }

    /// The history of `current` among `attempts`, which may include it.
    init(current: Int, attempts: [Attempt]) {
        let earlier = attempts.filter { $0.number < current }.sorted { $0.number < $1.number }
        isLatest = !attempts.contains { $0.number > current }
        previousPercent = earlier.last?.percent
        bestPercent = earlier.compactMap(\.percent).max()
    }

    /// The history of `submission`, read from the database.
    static func load(for submission: APISubmission, on db: any Database) async throws -> CelebrationHistory {
        let current = submission.attemptNumber ?? 1
        guard let userID = submission.userID else { return CelebrationHistory(current: current, attempts: []) }
        let submissions = try await APISubmission.query(on: db)
            .filter(\.$testSetupID == submission.testSetupID)
            .filter(\.$userID == userID)
            .filter(\.$kind == APISubmission.Kind.student)
            .all()
        let numbers = Dictionary(
            submissions.compactMap { row in row.id.map { ($0, row.attemptNumber ?? 1) } },
            uniquingKeysWith: { first, _ in first })
        let results = try await APIResult.query(on: db)
            .filter(\.$submissionID ~~ Array(numbers.keys))
            .sort(\.$receivedAt, .descending)
            .all()
        // One result per attempt: the worker's when there is one, as the
        // prior-attempt delta reads it, else the latest.
        var chosen: [String: APIResult] = [:]
        for result in results {
            if let held = chosen[result.submissionID], (held.source ?? "worker") == "worker" { continue }
            if chosen[result.submissionID] == nil || (result.source ?? "worker") == "worker" {
                chosen[result.submissionID] = result
            }
        }
        let attempts = chosen.compactMap { submissionID, result -> Attempt? in
            guard let number = numbers[submissionID] else { return nil }
            return Attempt(number: number, percent: result.gradePercentValue)
        }
        return CelebrationHistory(current: current, attempts: attempts)
    }
}
