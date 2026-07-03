// Core/Models/TestOutcomeCollectionTruncation.swift
//
// Total-size budget for a serialized TestOutcomeCollection (#1157). The
// worker caps each captured stream at 1 MB, but nothing capped the number
// of outcomes × longResult sizes: a many-test suite with verbose failures
// could exceed the server's result-ingest body limit, and the report was
// rejected — the submission never resolved. The budget is enforced at
// report time (worker + browser ingest) by truncating `longResult`s and
// `compilerOutput` across the whole collection; statuses, short results,
// and every aggregate stay intact.

import Foundation

extension TestOutcomeCollection {
    /// Default serialized-size budget: comfortably under the server's result
    /// ingest limit, leaving headroom for JSON escaping and the report
    /// envelope (diagnostics, attempt metadata).
    public static let defaultSerializedBudgetBytes = 6 * 1024 * 1024

    /// Marker appended to every truncated output so the student/instructor
    /// can see the cut was deliberate.
    public static let truncationMarker = "\n…[output truncated: result exceeded the size budget]"

    /// Returns a collection whose serialized size fits `budgetBytes`,
    /// truncating per-outcome `longResult`s (and `compilerOutput`) as evenly
    /// as needed. Returns `(self, false)` when already within budget.
    /// Statuses, short results, scores, and aggregates are never altered;
    /// a warning is appended when anything was cut.
    public func truncatingOversizedOutput(
        budgetBytes: Int = TestOutcomeCollection.defaultSerializedBudgetBytes
    ) -> (collection: TestOutcomeCollection, didTruncate: Bool) {
        guard serializedSize() > budgetBytes else { return (self, false) }

        // Everything except the long outputs is effectively fixed overhead;
        // the budget left for outputs is shared across the carriers. JSON
        // escaping can inflate the encoded size past the raw UTF-8 counts,
        // so shrink the per-carrier cap until the encoded form fits.
        let longBytes =
            outcomes.reduce(0) { $0 + ($1.longResult?.utf8.count ?? 0) }
            + (compilerOutput?.utf8.count ?? 0)
        let overhead = max(0, serializedSize() - longBytes)
        let carrierCount = max(
            1,
            outcomes.filter { ($0.longResult?.isEmpty == false) }.count
                + ((compilerOutput?.isEmpty == false) ? 1 : 0))

        var perCarrierCap = max(1024, (budgetBytes - overhead) / carrierCount)
        var truncated = self
        for _ in 0..<8 {
            truncated = truncatedCopy(perCarrierCap: perCarrierCap)
            if truncated.serializedSize() <= budgetBytes { break }
            perCarrierCap = max(256, perCarrierCap / 2)
        }
        return (truncated, true)
    }

    private func serializedSize() -> Int {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self).count) ?? 0
    }

    private func truncatedCopy(perCarrierCap: Int) -> TestOutcomeCollection {
        func cut(_ text: String?) -> String? {
            guard let text, text.utf8.count > perCarrierCap else { return text }
            // Cut on a character boundary near the byte cap; prefix(_:) on
            // characters keeps the result valid UTF-8.
            let kept = String(text.prefix(perCarrierCap))
            return kept + TestOutcomeCollection.truncationMarker
        }

        let cutOutcomes = outcomes.map { outcome in
            TestOutcome(
                testName: outcome.testName,
                testClass: outcome.testClass,
                tier: outcome.tier,
                status: outcome.status,
                shortResult: outcome.shortResult,
                longResult: cut(outcome.longResult),
                score: outcome.score,
                points: outcome.points,
                executionTimeMs: outcome.executionTimeMs,
                memoryUsageBytes: outcome.memoryUsageBytes,
                attemptNumber: outcome.attemptNumber,
                isFirstPassSuccess: outcome.isFirstPassSuccess
            )
        }

        var cutWarnings = warnings
        let notice = "Some test output was truncated because the result exceeded the size budget."
        if !cutWarnings.contains(notice) { cutWarnings.append(notice) }

        return TestOutcomeCollection(
            submissionID: submissionID,
            testSetupID: testSetupID,
            attemptNumber: attemptNumber,
            buildStatus: buildStatus,
            compilerOutput: cut(compilerOutput),
            outcomes: cutOutcomes,
            totalTests: totalTests,
            passCount: passCount,
            failCount: failCount,
            errorCount: errorCount,
            timeoutCount: timeoutCount,
            executionTimeMs: executionTimeMs,
            totalPoints: totalPoints,
            earnedPoints: earnedPoints,
            warnings: cutWarnings,
            jobStartedAt: jobStartedAt,
            runnerVersion: runnerVersion,
            timestamp: timestamp
        )
    }
}
