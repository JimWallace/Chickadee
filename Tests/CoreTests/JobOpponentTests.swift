// Tests/CoreTests/JobOpponentTests.swift
//
// The job's opponent descriptor (docs/class-activities.md, "Runner contract"):
// the seed's shape and determinism, and the wire back-compat in both
// directions — a job without the key decodes as an ordinary run.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@Suite struct JobOpponentTests {

    @Test func theMatchSeedIsSixtyFourLowercaseHexAndDeterministic() {
        let a = JobOpponent.matchSeed(submissionID: "sub_1", opponentIdentity: "supportFile:bot.py")
        let b = JobOpponent.matchSeed(submissionID: "sub_1", opponentIdentity: "supportFile:bot.py")
        #expect(a == b)
        #expect(a.count == 64)
        #expect(a.allSatisfy { "0123456789abcdef".contains($0) })
    }

    /// Two students never share a seed, and one student's seed changes with
    /// the opponent — a re-test against a replaced bot replays new trials.
    @Test func theSeedVariesWithSubmissionAndOpponent() {
        let base = JobOpponent.matchSeed(submissionID: "sub_1", opponentIdentity: "supportFile:bot.py")
        #expect(JobOpponent.matchSeed(submissionID: "sub_2", opponentIdentity: "supportFile:bot.py") != base)
        #expect(JobOpponent.matchSeed(submissionID: "sub_1", opponentIdentity: "supportFile:bot2.py") != base)
    }

    /// The source is spelled in front of the identity, so a bot whose name
    /// happens to equal a submission ID (slice 4's classmate identity) cannot
    /// derive the same seed.
    @Test func theSupportFileIdentityCarriesItsSource() {
        #expect(JobOpponent.supportFileIdentity("bot.py") == "supportFile:bot.py")
        #expect(JobOpponent.supportFileIdentity(nil) == "supportFile:")
    }

    /// A job from a server that predates the field, or an ordinary job from a
    /// current one, decodes with no opponent.
    @Test func aJobWithoutTheKeyDecodesAsAnOrdinaryRun() throws {
        let json = """
            {"submissionID":"s","testSetupID":"t","attemptNumber":1,
             "submissionURL":"https://x.test/s.zip","testSetupURL":"https://x.test/t.zip",
             "manifest":{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}}
            """
        let job = try JSONDecoder().decode(Job.self, from: Data(json.utf8))
        #expect(job.opponent == nil)
    }

    @Test func theOpponentRoundTripsOnTheJob() throws {
        let opponent = JobOpponent(supportFile: "bot.py", matchSeed: String(repeating: "ab", count: 32))
        let job = Job(
            submissionID: "s", testSetupID: "t", attemptNumber: 1,
            submissionURL: try #require(URL(string: "https://x.test/s.zip")),
            testSetupURL: try #require(URL(string: "https://x.test/t.zip")),
            manifest: TestProperties(), opponent: opponent)
        let decoded = try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job))
        #expect(decoded.opponent == opponent)
    }

    // MARK: - A submission opponent (slice 3)

    @Test func aSubmissionOpponentRoundTripsAndABotOpponentsBytesAreUnchanged() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bot = JobOpponent(supportFile: "bot.py", matchSeed: String(repeating: "ab", count: 32))
        let botJSON = try #require(String(data: encoder.encode(bot), encoding: .utf8))
        #expect(!botJSON.contains("submission"))
        #expect(!bot.stagesASubmission)

        let champion = JobOpponent(
            supportFile: nil, matchSeed: String(repeating: "cd", count: 32),
            submissionID: "sub_champ", submissionURL: testURL("https://x.test/c.zip"),
            submissionFilename: "strategy.py")
        let decoded = try JSONDecoder().decode(JobOpponent.self, from: encoder.encode(champion))
        #expect(decoded == champion)
        #expect(decoded.stagesASubmission)
        #expect(decoded.submissionFilename == "strategy.py")
    }

    // MARK: - A matrix of opponents (slice 4)

    /// A job from a server that predates the field, or a single-opponent job
    /// from a current one, decodes with no matrix.
    @Test func aJobWithoutTheOpponentsKeyDecodesWithNone() throws {
        let json = """
            {"submissionID":"s","testSetupID":"t","attemptNumber":1,
             "submissionURL":"https://x.test/s.zip","testSetupURL":"https://x.test/t.zip",
             "manifest":{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}}
            """
        let job = try JSONDecoder().decode(Job.self, from: Data(json.utf8))
        #expect(job.opponents == nil)
    }

    /// The matrix rides the job in order, and each opponent's identity is
    /// what the server opened its row under.
    @Test func theOpponentsRoundTripInOrderWithTheirIdentities() throws {
        let a = JobOpponent(
            supportFile: nil, matchSeed: String(repeating: "ab", count: 32),
            submissionID: "sub_a", submissionURL: testURL("https://x.test/a.zip"), submissionFilename: "a.py")
        let b = JobOpponent(
            supportFile: nil, matchSeed: String(repeating: "cd", count: 32),
            submissionID: "sub_b", submissionURL: testURL("https://x.test/b.zip"), submissionFilename: "b.py")
        let bot = JobOpponent(supportFile: "bot.py", matchSeed: String(repeating: "ef", count: 32))
        let job = Job(
            submissionID: "s", testSetupID: "t", attemptNumber: 1,
            submissionURL: testURL("https://x.test/s.zip"),
            testSetupURL: testURL("https://x.test/t.zip"),
            manifest: TestProperties(), opponents: [a, b])
        let decoded = try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job))
        #expect(decoded.opponents == [a, b])
        #expect(decoded.opponent == nil)
        #expect(a.identity == JobOpponent.submissionIdentity("sub_a"))
        #expect(bot.identity == JobOpponent.supportFileIdentity("bot.py"))
        #expect(JobOpponent(supportFile: nil, matchSeed: "x").identity == JobOpponent.noOpponentIdentity)
    }

    /// The per-match report the worker sends back for a matrix job, keyed by
    /// the same identity; `won` is the verdict, `score` and `metric` ride
    /// beside it exactly as the collection carries them.
    @Test func aMatchReportRoundTrips() throws {
        let report = MatchReport(
            opponentIdentity: "submission:sub_a", opponentSubmissionID: "sub_a",
            seed: String(repeating: "ab", count: 32), score: 0.75, metric: 3, won: true)
        let decoded = try JSONDecoder().decode(MatchReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
        let withoutEntry = MatchReport(
            opponentIdentity: "supportFile:bot.py", opponentSubmissionID: nil,
            seed: "s", score: nil, metric: nil, won: false)
        #expect(try JSONDecoder().decode(MatchReport.self, from: JSONEncoder().encode(withoutEntry)) == withoutEntry)
    }

    /// The report envelope carries the matches beside the collection, and a
    /// report from a runner that predates them decodes with none.
    @Test func theExecutionReportCarriesTheMatchesOptionally() throws {
        let collection = TestOutcomeCollection(
            submissionID: "s", testSetupID: "t", attemptNumber: 1, buildStatus: .passed,
            compilerOutput: nil, outcomes: [], totalTests: 0, passCount: 0, failCount: 0, errorCount: 0,
            timeoutCount: 0, executionTimeMs: 0, runnerVersion: "test", timestamp: Date())
        let bare = WorkerExecutionReport(collection: collection, diagnostics: nil)
        let bareData = try JSONEncoder().encode(bare)
        let bareJSON = try #require(String(data: bareData, encoding: .utf8))
        #expect(!bareJSON.contains("matches"))
        let report = WorkerExecutionReport(
            collection: collection, diagnostics: nil,
            matches: [
                MatchReport(
                    opponentIdentity: "none", opponentSubmissionID: nil, seed: "s", score: 1, metric: nil, won: true)
            ])
        let decoded = try JSONDecoder().decode(WorkerExecutionReport.self, from: JSONEncoder().encode(report))
        #expect(decoded.matches?.count == 1)
        #expect(decoded.matches?.first?.won == true)
    }

    /// The match entry — shared by the worker's per-match reports and the
    /// server's single-opponent path — is the highest-metric outcome.
    @Test func theMatchEntryIsTheHighestMetricOutcome() {
        func outcome(_ name: String, metric: Double?, status: TestStatus = .pass) -> TestOutcome {
            TestOutcome(
                testName: name, testClass: nil, tier: .pub, status: status,
                shortResult: "", longResult: nil, score: 1, metric: metric,
                executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: false)
        }
        #expect(
            matchOutcome(from: [
                outcome("gate", metric: nil), outcome("m", metric: 3, status: .fail), outcome("n", metric: 9),
            ])?.testName == "n")
        #expect(matchOutcome(from: [outcome("gate", metric: nil)]) == nil)
    }

    /// Identities are spelled with their source in front, so a champion's
    /// submission and a bot named after it never share a seed or a row.
    @Test func identitiesCarryTheirSource() {
        #expect(JobOpponent.submissionIdentity("abc") == "submission:abc")
        #expect(JobOpponent.supportFileIdentity("abc") == "supportFile:abc")
        #expect(JobOpponent.noOpponentIdentity == "none")
        #expect(
            JobOpponent.matchSeed(submissionID: "s", opponentIdentity: JobOpponent.submissionIdentity("abc"))
                != JobOpponent.matchSeed(submissionID: "s", opponentIdentity: JobOpponent.supportFileIdentity("abc")))
    }
}
