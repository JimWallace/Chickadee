// Tests/APITests/AuthoringChecks/RunAuthoringCheckTests.swift
//
// The authoring checks that read the stored validation runs, the placeholder
// names and the seed evaluations (#2747). Each builds an `AuthoringSnapshot` by
// hand, so none needs a database or a runner.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct RunAuthoringCheckTests {
    private func manifest(_ json: String) throws -> TestProperties {
        try #require(decodeManifest(fromJSON: json))
    }

    private let twoTests = """
        {"schemaVersion":1,"testSuites":[\
        {"tier":"public","script":"test_a.py","points":2,"name":"Part A"},\
        {"tier":"secret","script":"test_b.py","points":3,"timeLimitSeconds":4}\
        ],"timeLimitSeconds":10}
        """

    private func outcome(
        _ name: String, _ status: TestStatus, ms: Int = 100, metric: Double? = nil
    ) -> TestOutcome {
        TestOutcome(
            testName: name, testClass: nil, tier: .pub, status: status, shortResult: "",
            longResult: nil, metric: metric, executionTimeMs: ms, memoryUsageBytes: nil,
            attemptNumber: 1, isFirstPassSuccess: false)
    }

    private func run(_ outcomes: [TestOutcome], build: BuildStatus = .passed) -> TestOutcomeCollection {
        TestOutcomeCollection(
            submissionID: "sub", testSetupID: "setup", attemptNumber: 1, buildStatus: build,
            compilerOutput: nil, outcomes: outcomes, totalTests: outcomes.count, passCount: 0,
            failCount: 0, errorCount: 0, timeoutCount: 0, executionTimeMs: 0, runnerVersion: "test",
            timestamp: Date(timeIntervalSince1970: 0))
    }

    // MARK: - validation.variantFailed

    @Test func variantFailureNamesTheFailingTestsAndTheSeed() throws {
        var snapshot = AuthoringSnapshot(manifest: try manifest(twoTests))
        snapshot.variants = [
            .init(variantIndex: 0, seedHex: "aa", status: ValidationVariant.Status.passed, run: nil),
            .init(
                variantIndex: 1, seedHex: "bb", status: ValidationVariant.Status.failed,
                run: run([outcome("test_a", .pass), outcome("test_b", .fail)])),
            .init(variantIndex: 2, seedHex: "cc", status: ValidationVariant.Status.failed, run: nil),
        ]
        let findings = VariantFailureCheck().findings(in: snapshot)
        #expect(findings.count == 2)
        #expect(findings[0].message.contains("variant 1") && findings[0].message.contains("Failing: test_b."))
        #expect(findings[0].suggestedFix?.contains("seedHex bb") == true)
        #expect(findings[1].message.contains("could not be read"))
    }

    // MARK: - starter.passesGradedTest

    @Test func starterPassReportsOnlyGradedTestsTheSolutionAlsoPasses() throws {
        let manifest = try manifest(
            """
            {"schemaVersion":1,"testSuites":[\
            {"tier":"public","script":"test_a.py","points":2},\
            {"tier":"public","script":"test_b.py","points":0},\
            {"tier":"public","script":"test_c.py","points":1},\
            {"tier":"public","script":"test_d.py","points":1}\
            ],"timeLimitSeconds":10}
            """)
        var snapshot = AuthoringSnapshot(manifest: manifest)
        snapshot.starterRun = run([
            outcome("test_a", .pass), outcome("test_b", .pass), outcome("test_c", .pass), outcome("test_d", .fail),
        ])
        snapshot.solutionRun = run([
            outcome("test_a", .pass), outcome("test_b", .pass), outcome("test_c", .fail), outcome("test_d", .pass),
        ])
        let findings = StarterPassesCheck().findings(in: snapshot)
        #expect(findings.map(\.location) == [.suiteItem("test_a.py")])
        #expect(findings.first?.message.contains("2 points") == true)
    }

    @Test func aStarterThatDidNotRunSaysNothing() throws {
        var snapshot = AuthoringSnapshot(manifest: try manifest(twoTests))
        snapshot.starterRun = run([outcome("test_a", .pass)], build: .failed)
        snapshot.solutionRun = run([outcome("test_a", .pass)])
        #expect(StarterPassesCheck().findings(in: snapshot).isEmpty)
    }

    // MARK: - placeholders.unresolved

    @Test func unresolvedPlaceholderNamesEachUndeclaredInput() throws {
        let manifest = try manifest(
            """
            {"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10,\
            "globalVariables":[{"name":"limit","value":5}],\
            "globalExpressions":[{"name":"offset","expression":"seed % 3"}],\
            "sections":[{"id":"s1","name":"Part 1","variables":[{"name":"rate","value":2}]}]}
            """)
        var snapshot = AuthoringSnapshot(manifest: manifest)
        snapshot.placeholderNames = ["limit", "offset", "rate", "zeta", "alpha"]
        let findings = UnresolvedPlaceholderCheck().findings(in: snapshot)
        #expect(findings.map(\.location) == [.input("alpha"), .input("zeta")])
        #expect(findings.allSatisfy { $0.severity == .error })
    }

    /// Substitution reads code cells only, so a marker in markdown is not a use.
    @Test func placeholderNamesComeFromTheNotebooksCodeCells() throws {
        let notebook =
            #"{"cells":[{"cell_type":"markdown","metadata":{},"source":["About {{rate}}."]},"#
            + #"{"cell_type":"code","execution_count":null,"metadata":{},"outputs":[],"#
            + #""source":["n = {{limit}}\n"]}],"metadata":{},"nbformat":4,"nbformat_minor":5}"#
        let names = PersonalizationPlaceholders.used(
            notebookData: Data(notebook.utf8), manifest: try manifest(TestManifests.emptySuite))
        #expect(names == ["limit"])
    }

    // MARK: - personalization.expressionError

    @Test func expressionErrorsGroupSeedsBySameError() throws {
        var snapshot = AuthoringSnapshot(manifest: try manifest(twoTests))
        snapshot.seedEvaluations = [
            .init(seedHex: "s0", error: "NameError: x"),
            .init(seedHex: "s1", error: nil),
            .init(seedHex: "s2", error: "NameError: x"),
            .init(seedHex: "s3", error: "ZeroDivisionError"),
        ]
        let findings = ExpressionErrorCheck().findings(in: snapshot)
        #expect(findings.count == 2)
        #expect(findings[0].message.hasPrefix("The per-student expressions fail for 2 of 4"))
        #expect(findings[0].suggestedFix?.contains("seedHex s0") == true)
        #expect(findings[1].message.contains("ZeroDivisionError"))
    }

    // MARK: - timing.margin

    @Test func timingMarginUsesTheEntryLimitThenTheAssignmentLimit() throws {
        var snapshot = AuthoringSnapshot(manifest: try manifest(twoTests))
        // test_a: 6 s of the assignment's 10 s. test_b: 1.5 s of its own 4 s.
        snapshot.solutionRun = run([outcome("test_a", .pass, ms: 6000), outcome("test_b", .pass, ms: 1500)])
        let findings = TimingMarginCheck().findings(in: snapshot)
        #expect(findings.map(\.location) == [.suiteItem("test_a.py")])
        #expect(findings.first?.message.contains("6.0 s of the 10 s limit on Part A") == true)
        #expect(findings.first?.suggestedFix?.contains("at least 12 s") == true)
    }

    @Test func timingMarginIgnoresATimedOutTest() throws {
        var snapshot = AuthoringSnapshot(manifest: try manifest(twoTests))
        snapshot.solutionRun = run([outcome("test_b", .timeout, ms: 4000)])
        #expect(TimingMarginCheck().findings(in: snapshot).isEmpty)
    }

    // MARK: - activity.noMetric

    @Test func missingMetricFiresOnlyForALeaderboardActivity() throws {
        let leaderboard = try manifest(
            #"{"schemaVersion":1,"testSuites":[{"tier":"public","script":"test_a.py"}],"timeLimitSeconds":10,"#
                + #""activity":{"kind":"bestMetric","leaderboardVisibility":"visible"}}"#)
        var snapshot = AuthoringSnapshot(manifest: leaderboard)
        snapshot.solutionRun = run([outcome("test_a", .pass)])
        #expect(MissingMetricCheck().findings(in: snapshot).map(\.checkID) == ["activity.noMetric"])

        snapshot.solutionRun = run([outcome("test_a", .pass, metric: 0.5)])
        #expect(MissingMetricCheck().findings(in: snapshot).isEmpty)

        var noActivity = AuthoringSnapshot(manifest: try manifest(twoTests))
        noActivity.solutionRun = run([outcome("test_a", .pass)])
        #expect(MissingMetricCheck().findings(in: noActivity).isEmpty)
    }

    // MARK: - The outcome join

    @Test func outcomesJoinByFilenameOrStem() throws {
        let joined = run([outcome("test_a", .pass), outcome("test_b.py", .fail)])
            .outcomesByScript(in: try manifest(twoTests))
        #expect(joined["test_a.py"]?.status == .pass)
        #expect(joined["test_b.py"]?.status == .fail)
    }
}
