// Tests/APITests/AuthoringChecks/StarterRunCheckTests.swift
//
// The step-6 authoring checks that read the starter run (#2747):
// `starter.didNotRun` and `starter.errorsInsteadOfFails`. Each builds an
// `AuthoringSnapshot` by hand.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct StarterRunCheckTests {
    private let threeTests = """
        {"schemaVersion":1,"testSuites":[\
        {"tier":"public","script":"test_a.py","points":2,"name":"Mean"},\
        {"tier":"public","script":"test_b.py","points":1},\
        {"tier":"public","script":"test_c.py","points":0}\
        ],"timeLimitSeconds":10}
        """

    private func outcome(_ name: String, _ status: TestStatus) -> TestOutcome {
        TestOutcome(
            testName: name, testClass: nil, tier: .pub, status: status, shortResult: "",
            longResult: nil, executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1,
            isFirstPassSuccess: false)
    }

    private func run(
        _ outcomes: [TestOutcome], build: BuildStatus = .passed, compilerOutput: String? = nil
    ) -> TestOutcomeCollection {
        TestOutcomeCollection(
            submissionID: "sub", testSetupID: "setup", attemptNumber: 1, buildStatus: build,
            compilerOutput: compilerOutput, outcomes: outcomes, totalTests: outcomes.count, passCount: 0,
            failCount: 0, errorCount: 0, timeoutCount: 0, executionTimeMs: 0, runnerVersion: "test",
            timestamp: Date(timeIntervalSince1970: 0))
    }

    private func snapshot(starter: TestOutcomeCollection?) throws -> AuthoringSnapshot {
        var snapshot = AuthoringSnapshot(manifest: try #require(decodeManifest(fromJSON: threeTests)))
        snapshot.solutionRun = run([outcome("test_a", .pass), outcome("test_b", .pass), outcome("test_c", .pass)])
        snapshot.starterRun = starter
        return snapshot
    }

    // MARK: - starter.didNotRun

    @Test func aStarterThatDoesNotBuildIsReportedWithItsReason() throws {
        let snapshot = try snapshot(
            starter: run([], build: .failed, compilerOutput: "SyntaxError: invalid syntax\nline 2"))
        let findings = StarterDidNotRunCheck().findings(in: snapshot)
        #expect(findings.map(\.checkID) == ["starter.didNotRun"])
        #expect(findings.first?.message.contains("SyntaxError: invalid syntax") == true)
        #expect(StarterErrorCheck().findings(in: snapshot).isEmpty)
    }

    @Test func aStarterThatErrorsOnEveryTestDidNotRun() throws {
        let snapshot = try snapshot(
            starter: run([outcome("test_a", .error), outcome("test_b", .error), outcome("test_c", .error)]))
        #expect(StarterDidNotRunCheck().findings(in: snapshot).count == 1)
        #expect(StarterErrorCheck().findings(in: snapshot).isEmpty)
    }

    @Test func noStarterRunOrARunningStarterIsQuiet() throws {
        #expect(StarterDidNotRunCheck().findings(in: try snapshot(starter: nil)).isEmpty)
        let ran = try snapshot(starter: run([outcome("test_a", .fail), outcome("test_b", .fail)]))
        #expect(StarterDidNotRunCheck().findings(in: ran).isEmpty)
    }

    // MARK: - starter.errorsInsteadOfFails

    @Test func gradedTestsThatErrorOnTheStarterAreListedOnce() throws {
        let snapshot = try snapshot(
            starter: run([outcome("test_a", .error), outcome("test_b", .fail), outcome("test_c", .error)]))
        let findings = StarterErrorCheck().findings(in: snapshot)
        #expect(findings.count == 1)
        #expect(findings.first?.severity == .info)
        // test_c errors too, but it is worth no points.
        #expect(findings.first?.message.hasPrefix("1 graded test reports an error") == true)
        #expect(findings.first?.message.contains(": Mean.") == true)
    }

    @Test func aTestTheSolutionFailsIsNotListed() throws {
        var snapshot = try snapshot(starter: run([outcome("test_a", .error), outcome("test_b", .fail)]))
        snapshot.solutionRun = run([outcome("test_a", .fail), outcome("test_b", .pass)])
        #expect(StarterErrorCheck().findings(in: snapshot).isEmpty)
    }
}
