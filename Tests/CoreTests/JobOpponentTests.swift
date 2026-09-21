// Tests/CoreTests/JobOpponentTests.swift
//
// The job's opponent descriptor (docs/class-activities.md, "Runner contract"):
// the seed's shape and determinism, and the wire back-compat in both
// directions — a job without the key decodes as an ordinary run.

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
}
