// APIServer/Helpers/TierFilter.swift
//
// Tier-visibility helpers shared between the web UI and the JSON API.
//
// Visibility rules:
//   public   — always visible to students and instructors
//   release  — visible to students only after the assignment deadline passes
//              (or immediately when the assignment has no deadline)
//   secret   — never visible to students; always visible to instructors/admins

import Core
import Foundation

// MARK: - Collection filtering

extension TestOutcomeCollection {
    /// Returns a copy filtered to the given tier raw-value set, with all
    /// aggregate counts recomputed from the surviving outcomes.
    func filtering(tiers: Set<String>) -> TestOutcomeCollection {
        let filtered = outcomes.filter { tiers.contains($0.tier.rawValue) }
        return TestOutcomeCollection(
            submissionID: submissionID,
            testSetupID: testSetupID,
            attemptNumber: attemptNumber,
            buildStatus: buildStatus,
            compilerOutput: compilerOutput,
            outcomes: filtered,
            totalTests: filtered.count,
            passCount: filtered.filter { $0.status == .pass }.count,
            failCount: filtered.filter { $0.status == .fail }.count,
            errorCount: filtered.filter { $0.status == .error }.count,
            timeoutCount: filtered.filter { $0.status == .timeout }.count,
            executionTimeMs: executionTimeMs,
            totalPoints: filtered.reduce(0) { $0 + $1.points },
            earnedPoints: filtered.filter { $0.status == .pass }.reduce(0) { $0 + $1.points },
            warnings: warnings,
            jobStartedAt: jobStartedAt,
            runnerVersion: runnerVersion,
            timestamp: timestamp
        )
    }
}

// MARK: - Tier visibility policy

/// Returns the set of tier raw-value strings that `user` is permitted to see
/// for the given assignment (or nil assignment = no deadline context).
///
/// - Instructors and admins always see all three tiers.
/// - Students see `public` always, `release` after the deadline passes
///   (or immediately when there is no deadline), and never `secret`.
func visibleTiers(for user: APIUser, assignment: APIAssignment?) -> Set<String> {
    if user.isInstructor {
        return ["public", "release", "secret"]
    }
    // nil dueAt → no deadline → release is immediately visible.
    let releaseVisible = assignment?.dueAt.map { $0 <= Date() } ?? true
    return releaseVisible ? ["public", "release"] : ["public"]
}

func visibleCollection(
    from collectionJSON: String,
    for user: APIUser,
    assignment: APIAssignment?
) -> TestOutcomeCollection? {
    guard let data = collectionJSON.data(using: .utf8) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let collection = try? decoder.decode(TestOutcomeCollection.self, from: data) else { return nil }
    return collection.filtering(tiers: visibleTiers(for: user, assignment: assignment))
}

func gradePercent(from collection: TestOutcomeCollection) -> Int? {
    guard collection.totalPoints > 0 else { return nil }
    return Int((Double(collection.earnedPoints) / Double(collection.totalPoints) * 100).rounded())
}
