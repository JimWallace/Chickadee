// Tests/CoreTests/TestOutcomeCollectionTruncationTests.swift
//
// #1157: the serialized-size budget for a result collection. Statuses,
// short results, and aggregates must never change; only longResults and
// compilerOutput shrink, with a visible marker + warning.

import Foundation
import Testing

@testable import Core

@Suite struct TestOutcomeCollectionTruncationTests {

    private func makeCollection(
        outcomeCount: Int,
        longResultBytes: Int,
        compilerOutput: String? = nil
    ) -> TestOutcomeCollection {
        let longResult = String(repeating: "x", count: longResultBytes)
        let outcomes = (0..<outcomeCount).map { index in
            TestOutcome(
                testName: "test_\(index)",
                testClass: nil,
                tier: .pub,
                status: index % 2 == 0 ? .pass : .fail,
                shortResult: "short \(index)",
                longResult: longResult,
                executionTimeMs: 5,
                memoryUsageBytes: nil,
                attemptNumber: 1,
                isFirstPassSuccess: false
            )
        }
        return TestOutcomeCollection(
            submissionID: "sub_trunc",
            testSetupID: "setup_trunc",
            attemptNumber: 1,
            buildStatus: .passed,
            compilerOutput: compilerOutput,
            outcomes: outcomes,
            totalTests: outcomeCount,
            passCount: (outcomeCount + 1) / 2,
            failCount: outcomeCount / 2,
            errorCount: 0,
            timeoutCount: 0,
            executionTimeMs: 100,
            runnerVersion: "shell-runner/1.0",
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    private func serializedSize(_ collection: TestOutcomeCollection) throws -> Int {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(collection).count
    }

    @Test func smallCollectionIsUntouched() throws {
        let collection = makeCollection(outcomeCount: 5, longResultBytes: 1000)
        let (result, didTruncate) = collection.truncatingOversizedOutput()
        #expect(!didTruncate)
        #expect(result.outcomes.map(\.longResult) == collection.outcomes.map(\.longResult))
        #expect(result.warnings.isEmpty)
    }

    @Test func oversizedCollectionFitsBudgetAndKeepsGrades() throws {
        // 60 outcomes x 200 KB = ~12 MB of longResult against a 1 MB budget.
        let collection = makeCollection(outcomeCount: 60, longResultBytes: 200_000)
        let budget = 1024 * 1024
        let (result, didTruncate) = collection.truncatingOversizedOutput(budgetBytes: budget)

        #expect(didTruncate)
        #expect(try serializedSize(result) <= budget)

        // Grade-relevant content is untouched.
        #expect(result.outcomes.count == collection.outcomes.count)
        #expect(result.outcomes.map(\.status) == collection.outcomes.map(\.status))
        #expect(result.outcomes.map(\.shortResult) == collection.outcomes.map(\.shortResult))
        #expect(result.passCount == collection.passCount)
        #expect(result.totalPoints == collection.totalPoints)
        #expect(result.earnedPoints == collection.earnedPoints)

        // Every truncated output carries the marker, and the collection
        // carries a warning.
        #expect(
            result.outcomes.allSatisfy {
                $0.longResult?.hasSuffix(TestOutcomeCollection.truncationMarker) == true
            })
        #expect(result.warnings.contains { $0.contains("truncated") })
    }

    @Test func compilerOutputParticipatesInBudget() throws {
        let collection = makeCollection(
            outcomeCount: 1, longResultBytes: 100,
            compilerOutput: String(repeating: "e", count: 3_000_000))
        let budget = 512 * 1024
        let (result, didTruncate) = collection.truncatingOversizedOutput(budgetBytes: budget)
        #expect(didTruncate)
        #expect(try serializedSize(result) <= budget)
        #expect(result.compilerOutput?.hasSuffix(TestOutcomeCollection.truncationMarker) == true)
    }

    @Test func roundTripsThroughCodableAfterTruncation() throws {
        let collection = makeCollection(outcomeCount: 20, longResultBytes: 300_000)
        let (result, _) = collection.truncatingOversizedOutput(budgetBytes: 512 * 1024)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            TestOutcomeCollection.self, from: encoder.encode(result))
        #expect(decoded.outcomes.count == 20)
        #expect(decoded.passCount == result.passCount)
    }

    // MARK: - Who shares the budget

    /// `outputCarrierCount` is the divisor the per-carrier cap is computed
    /// from. It is asserted directly because it cannot be seen from outside:
    /// the halving loop retries until the encoded form fits, so a wrong
    /// divisor still produces a collection within budget — it just splits the
    /// budget unfairly, keeping roughly twice or half as much output as it
    /// should.
    ///
    /// The 2026-08-19 sweep (run 32265903112) found both mutants of the
    /// `compilerOutput` term surviving on exactly that basis. Neither can
    /// break the budget guarantee, which is what every existing test here
    /// checks, and both silently change how much of a student's output
    /// survives.
    @Test func nonEmptyCompilerOutputIsOneOfTheCarriers() {
        let withOutput = makeCollection(
            outcomeCount: 3, longResultBytes: 100, compilerOutput: "boom")
        #expect(withOutput.outputCarrierCount == 4)

        let withoutOutput = makeCollection(outcomeCount: 3, longResultBytes: 100)
        #expect(withoutOutput.outputCarrierCount == 3)
    }

    /// An empty string is not output. Counting it would reserve a share of the
    /// budget for a carrier that has nothing to truncate, shrinking everyone
    /// else's for no gain — and it is the case both mutants get backwards.
    @Test func emptyCompilerOutputIsNotACarrier() {
        let empty = makeCollection(outcomeCount: 2, longResultBytes: 100, compilerOutput: "")
        #expect(empty.outputCarrierCount == 2)

        let nilOutput = makeCollection(outcomeCount: 2, longResultBytes: 100)
        #expect(nilOutput.outputCarrierCount == 2)
    }

    /// The same rule on the outcome side, so the count is pinned whole rather
    /// than only at the term the sweep happened to mutate.
    @Test func onlyOutcomesWithOutputAreCarriers() {
        let quiet = makeCollection(outcomeCount: 4, longResultBytes: 0)
        #expect(quiet.outputCarrierCount == 0, "an empty longResult carries nothing")

        let mixed = makeCollection(outcomeCount: 4, longResultBytes: 0, compilerOutput: "boom")
        #expect(mixed.outputCarrierCount == 1)
    }

    /// A collection with nothing to truncate must still divide by something.
    /// The `max(1, …)` at the call site is what stops that; asserting the raw
    /// count is zero is what makes the guard's existence visible here.
    @Test func aCollectionWithNoOutputHasNoCarriersAndStillTruncatesSafely() {
        let quiet = makeCollection(outcomeCount: 3, longResultBytes: 0)
        #expect(quiet.outputCarrierCount == 0)
        let (result, didTruncate) = quiet.truncatingOversizedOutput(budgetBytes: 100)
        #expect(didTruncate)
        #expect(result.outcomes.count == 3)
    }

}
