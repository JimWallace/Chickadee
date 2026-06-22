// APIServer/Helpers/TierFilter.swift
//
// Tier-visibility helpers shared between the web UI and the JSON API.
//
// The grade is always computed over every tier, so the percentage is identical
// on the dashboard and the submission page and does not jump at the deadline.
// What the deadline (and tier) gate is *presentation*:
//   public   — listed by name with full output, always
//   release  — listed by name always (so a student knows which hidden tests
//              they're failing), but the per-test output is hidden until the
//              deadline passes (or immediately when there is no deadline)
//   secret   — never itemized; shown to students only as an aggregate pass/fail
//              count.  Always fully visible to instructors/admins.

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
            earnedPoints: filtered.reduce(0.0) { $0 + Double($1.points) * $1.score },
            warnings: warnings,
            jobStartedAt: jobStartedAt,
            runnerVersion: runnerVersion,
            timestamp: timestamp
        )
    }

    /// Returns a copy with `outcomes` swapped out but every aggregate field
    /// (counts, points, build status, metadata) left intact.  Used by the
    /// results API so the response carries the real all-tier grade while
    /// listing only the caller-visible outcomes — the aggregates therefore may
    /// not sum to `outcomes`, by design.
    func replacingOutcomes(with newOutcomes: [TestOutcome]) -> TestOutcomeCollection {
        TestOutcomeCollection(
            submissionID: submissionID,
            testSetupID: testSetupID,
            attemptNumber: attemptNumber,
            buildStatus: buildStatus,
            compilerOutput: compilerOutput,
            outcomes: newOutcomes,
            totalTests: totalTests,
            passCount: passCount,
            failCount: failCount,
            errorCount: errorCount,
            timeoutCount: timeoutCount,
            executionTimeMs: executionTimeMs,
            totalPoints: totalPoints,
            earnedPoints: earnedPoints,
            warnings: warnings,
            jobStartedAt: jobStartedAt,
            runnerVersion: runnerVersion,
            timestamp: timestamp
        )
    }
}

// MARK: - Tier visibility policy

/// Returns the set of tier raw-value strings whose *individual outcomes* a
/// caller may receive verbatim through the raw results API for the given
/// assignment.  This is the conservative "may hand back full detail" gate used
/// by `GET /api/v1/submissions/:id/results`:
///
/// - Instructors and admins always see all three tiers.
/// - Students see `public` always, `release` after the deadline passes
///   (or immediately when there is no deadline), and never `secret`.
///
/// `effectiveDueAt` is the deadline that actually applies to the student whose
/// submission is being viewed — the *later* of the assignment-wide due date and
/// that student's per-student extension (see `effectiveDueAt(for:user:on:)`).
/// Gating on the effective deadline rather than the bare assignment due date
/// means an accommodated student does not get the hidden release tests revealed
/// while their own extended window is still open.
///
/// The student *web* view is more nuanced — it lists release tests by name
/// before the deadline but redacts their output — so it uses `itemizedTiers`
/// and `releaseOutputVisible` instead.
func visibleTiers(for user: APIUser, effectiveDueAt: Date?, now: Date = Date()) -> Set<String> {
    if user.isInstructor {
        return ["public", "release", "secret"]
    }
    // nil effectiveDueAt → no deadline → release is immediately visible.
    let releaseVisible = effectiveDueAt.map { $0 <= now } ?? true
    return releaseVisible ? ["public", "release"] : ["public"]
}

/// Tiers whose individual test rows are itemized (listed by name) in the
/// student submission view.  Students always see `public` and `release` rows —
/// release names are shown even before the deadline so a student knows which
/// hidden tests they are failing — but `secret` is never itemized.  Instructors
/// see every tier.  The grade is computed over *all* tiers regardless of this
/// set, so the number is stable across the deadline; only release *output* is
/// additionally gated (see `releaseOutputVisible`).
func itemizedTiers(for user: APIUser) -> Set<String> {
    user.isInstructor ? ["public", "release", "secret"] : ["public", "release"]
}

/// Whether release-tier *output* (the result message + stderr/traceback panel)
/// is shown to `user`.  Release rows are always listed by name for students,
/// but their detailed output stays hidden until the deadline passes so students
/// can't read the expected/actual values early.  Instructors always see it.
///
/// `effectiveDueAt` is the deadline that applies to the viewing student — the
/// later of the assignment due date and their own extension — so a student with
/// an active extension keeps release output hidden until *their* deadline
/// passes, not the (earlier) class-wide one.
func releaseOutputVisible(for user: APIUser, effectiveDueAt: Date?, now: Date = Date()) -> Bool {
    if user.isInstructor { return true }
    return effectiveDueAt.map { $0 <= now } ?? true
}

/// Decodes a stored collection JSON with no tier filtering — the full,
/// all-tier collection the runner reported.  Used wherever the *grade* is
/// needed (it is computed over every tier), as opposed to the tier-filtered
/// itemized rows.
func decodedCollection(from collectionJSON: String) -> TestOutcomeCollection? {
    guard let data = collectionJSON.data(using: .utf8) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(TestOutcomeCollection.self, from: data)
}

func gradePercent(from collection: TestOutcomeCollection) -> Int? {
    guard collection.totalPoints > 0 else { return nil }
    return Int((collection.earnedPoints / Double(collection.totalPoints) * 100).rounded())
}
