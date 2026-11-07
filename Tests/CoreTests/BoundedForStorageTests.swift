// Tests/CoreTests/BoundedForStorageTests.swift
//
// `boundedForStorage` returns the JSON it measured the collection with, so
// the result-ingest path stores those bytes instead of encoding the
// collection a second time. The bytes must be the encoding of exactly the
// collection it returns, and its collection and truncation flag must be the
// ones `truncatingOversizedOutput` returns.

import Foundation
import Testing

@testable import Core

@Suite struct BoundedForStorageTests {

    private func makeCollection(outcomeCount: Int, longResultBytes: Int) -> TestOutcomeCollection {
        let longResult = String(repeating: "x", count: longResultBytes)
        let outcomes = (0..<outcomeCount).map { index in
            TestOutcome(
                testName: "test_\(index)",
                testClass: nil,
                tier: .pub,
                status: index.isMultiple(of: 2) ? .pass : .fail,
                shortResult: "short \(index)",
                longResult: longResult,
                executionTimeMs: 5,
                memoryUsageBytes: nil,
                attemptNumber: 1,
                isFirstPassSuccess: false
            )
        }
        return TestOutcomeCollection(
            submissionID: "sub_bounded",
            testSetupID: "setup_bounded",
            attemptNumber: 1,
            buildStatus: .passed,
            compilerOutput: "warning: unused variable",
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

    private func encoded(_ collection: TestOutcomeCollection) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(collection)
    }

    /// One collection size against one budget.
    struct Case: Sendable, CustomTestStringConvertible {
        let outcomeCount: Int
        let longResultBytes: Int
        let budgetBytes: Int

        var testDescription: String {
            "\(outcomeCount) outcomes of \(longResultBytes) bytes, budget \(budgetBytes)"
        }
    }

    @Test(arguments: [
        Case(
            outcomeCount: 5, longResultBytes: 1000,
            budgetBytes: TestOutcomeCollection.defaultSerializedBudgetBytes),
        Case(outcomeCount: 40, longResultBytes: 4096, budgetBytes: 50_000),
        Case(outcomeCount: 3, longResultBytes: 100_000, budgetBytes: 20_000),
    ])
    func theJSONIsTheEncodingOfTheReturnedCollection(_ testCase: Case) throws {
        let collection = makeCollection(
            outcomeCount: testCase.outcomeCount, longResultBytes: testCase.longResultBytes)

        let bounded = collection.boundedForStorage(budgetBytes: testCase.budgetBytes)
        let truncated = collection.truncatingOversizedOutput(budgetBytes: testCase.budgetBytes)

        let json = try #require(bounded.json)
        #expect(json == (try encoded(bounded.collection)))
        #expect(json == (try encoded(truncated.collection)))
        #expect(bounded.didTruncate == truncated.didTruncate)
        #expect(bounded.didTruncate == ((try encoded(collection)).count > testCase.budgetBytes))
    }
}
