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
