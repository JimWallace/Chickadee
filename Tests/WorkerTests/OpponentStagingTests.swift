// Tests/WorkerTests/OpponentStagingTests.swift
//
// The worker half of the opponent primitive (docs/class-activities.md, "Runner
// contract"): what gets staged where, the environment a match script sees,
// the loud failures, the build capability — and one real match, the
// rock-paper-scissors fixture played through `executeSuites` with the exact
// environment the daemon sets.

import Core
import Foundation
import RunnerCore
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) struct OpponentStagingTests {

    private static let fixturesDir: URL = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()  // OpponentStagingTests.swift
        url.deleteLastPathComponent()  // WorkerTests
        return url.appendingPathComponent("Fixtures").appendingPathComponent("activity-match")
    }()

    private static func makeDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-opponent-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func job(opponent: JobOpponent?) throws -> Job {
        Job(
            submissionID: "sub_match", testSetupID: "setup_match", attemptNumber: 1,
            submissionURL: try #require(URL(string: "https://x.test/s.zip")),
            testSetupURL: try #require(URL(string: "https://x.test/t.zip")),
            manifest: TestProperties(), submissionFilename: "strategy.py",
            opponent: opponent)
    }

    private static let seed = JobOpponent.matchSeed(
        submissionID: "sub_match", opponentIdentity: JobOpponent.supportFileIdentity("bot.py"))

    /// An ordinary job stages nothing and adds nothing to the environment:
    /// its bytes on the wire and in the script's env are what they always were.
    @Test func anOrdinaryJobStagesNothing() throws {
        let work = try Self.makeDir("plain")
        defer { try? FileManager.default.removeItem(at: work) }
        let job = try Self.job(opponent: nil)
        #expect(try stageOpponentWorkspace(job: job, workDir: work, testSetupDir: work) == nil)
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("opponent").path))
        #expect(opponentScriptEnvironment(job: job, opponentDir: nil).isEmpty)
    }

    /// The bot lands under its own name in `<work>/opponent/`, outside the
    /// test-setup directory, and both env keys point the script at it.
    @Test func theSupportFileIsStagedUnderItsOwnNameBesideTheSetup() throws {
        let work = try Self.makeDir("stage")
        defer { try? FileManager.default.removeItem(at: work) }
        let setup = work.appendingPathComponent("setup", isDirectory: true)
        try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true)
        try "print('rock')\n".write(to: setup.appendingPathComponent("bot.py"), atomically: true, encoding: .utf8)

        let job = try Self.job(opponent: JobOpponent(supportFile: "bot.py", matchSeed: Self.seed))
        let staged = try #require(try stageOpponentWorkspace(job: job, workDir: work, testSetupDir: setup))
        #expect(staged == work.appendingPathComponent("opponent", isDirectory: true))
        #expect(
            try String(contentsOf: staged.appendingPathComponent("bot.py"), encoding: .utf8)
                == "print('rock')\n")
        #expect(!FileManager.default.fileExists(atPath: setup.appendingPathComponent("opponent").path))

        let env = opponentScriptEnvironment(job: job, opponentDir: staged)
        #expect(env[OpponentEnvironment.directory] == staged.path)
        #expect(env[OpponentEnvironment.matchSeed] == Self.seed)
        // Both keys are in the namespace the script runner lets through.
        #expect(env.keys.allSatisfy { $0.hasPrefix("CHICKADEE_") })
    }

    /// The three refusals, each naming its fix: no file chosen, a file the
    /// setup lacks, a name that is not bare.
    @Test func aMatchWithNoStageableOpponentFailsLoudly() throws {
        let work = try Self.makeDir("refuse")
        defer { try? FileManager.default.removeItem(at: work) }

        let unchosen = try Self.job(opponent: JobOpponent(supportFile: nil, matchSeed: Self.seed))
        #expect(throws: WorkerDaemonError.self) {
            try stageOpponentWorkspace(job: unchosen, workDir: work, testSetupDir: work)
        }
        do {
            _ = try stageOpponentWorkspace(job: unchosen, workDir: work, testSetupDir: work)
        } catch let error as WorkerDaemonError {
            #expect(error.errorDescription?.contains("no opponent file is chosen") == true)
        }

        let missing = try Self.job(opponent: JobOpponent(supportFile: "ghost.py", matchSeed: Self.seed))
        do {
            _ = try stageOpponentWorkspace(job: missing, workDir: work, testSetupDir: work)
            Issue.record("a missing opponent file must throw")
        } catch let error as WorkerDaemonError {
            #expect(error.errorDescription?.contains("ghost.py") == true)
            #expect(error.errorDescription?.contains("not in the test setup") == true)
        }

        let traversal = try Self.job(
            opponent: JobOpponent(supportFile: "../secret.py", matchSeed: Self.seed))
        do {
            _ = try stageOpponentWorkspace(job: traversal, workDir: work, testSetupDir: work)
            Issue.record("a path-carrying opponent name must throw")
        } catch let error as WorkerDaemonError {
            #expect(error.errorDescription?.contains("not a bare filename") == true)
        }
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("opponent").path))
    }

    /// Every profile this build advertises says it can stage an opponent —
    /// that is what lets `RunnerActivityGate` hand it a match job.
    @Test func thisBuildAdvertisesTheMatchCapability() {
        #expect(RunnerProfileDetector.buildCapabilities.contains(.activityMatch))
        #expect(RunnerCapability.activityMatch.name == "activity-match")
    }

    /// The rock-paper-scissors fixture, end to end: the student's paper beats
    /// the bot's rock every round, through the same executor and environment
    /// the daemon builds. Exercises the whole contract a match script relies
    /// on — the staged file's path, the seed, `metric` in the footer.
    @Test func theFixtureMatchIsGradedWithTheStagedOpponent() async throws {
        let work = try Self.makeDir("rps")
        defer { try? FileManager.default.removeItem(at: work) }
        let setup = work.appendingPathComponent("setup", isDirectory: true)
        try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true)
        let fm = FileManager.default
        try fm.copyItem(
            at: Self.fixturesDir.appendingPathComponent("match_rps.sh"),
            to: setup.appendingPathComponent("match_rps.sh"))
        // The bot is a support file named like the student's required file, so
        // one script reads both through the same name.
        try fm.copyItem(
            at: Self.fixturesDir.appendingPathComponent("bot_strategy.py"),
            to: setup.appendingPathComponent("strategy.py"))
        let job = try Self.job(opponent: JobOpponent(supportFile: "strategy.py", matchSeed: Self.seed))
        let opponentDir = try #require(try stageOpponentWorkspace(job: job, workDir: work, testSetupDir: setup))
        // Now the submission takes the setup's `strategy.py` slot, as staging does.
        try fm.removeItem(at: setup.appendingPathComponent("strategy.py"))
        try fm.copyItem(
            at: Self.fixturesDir.appendingPathComponent("student_strategy.py"),
            to: setup.appendingPathComponent("strategy.py"))

        let executor = NativeScriptExecutor(
            runner: UnsandboxedScriptRunner(), workDir: setup,
            env: opponentScriptEnvironment(job: job, opponentDir: opponentDir))
        let outcomes = await executeSuites(
            [SuiteItem(script: "match_rps.sh", tier: .pub, displayName: "match", dependsOn: [], points: 1)],
            timeLimitSeconds: 30, attemptNumber: 1, executor: executor)
        let outcome = try #require(outcomes.first)
        #expect(outcome.status == .pass, "stderr: \(outcome.longResult ?? "")")
        #expect(outcome.score == 1)
        #expect(outcome.metric == 5)
        #expect(outcome.shortResult == "5/5 rounds won")
        #expect(outcome.longResult?.contains("seed=\(Self.seed)") == true)
    }

    /// The same script with no opponent staged errors rather than passing —
    /// the property the whole primitive exists for.
    @Test func theFixtureMatchErrorsWithoutAnOpponent() async throws {
        let setup = try Self.makeDir("rps-none")
        defer { try? FileManager.default.removeItem(at: setup) }
        try FileManager.default.copyItem(
            at: Self.fixturesDir.appendingPathComponent("match_rps.sh"),
            to: setup.appendingPathComponent("match_rps.sh"))
        try FileManager.default.copyItem(
            at: Self.fixturesDir.appendingPathComponent("student_strategy.py"),
            to: setup.appendingPathComponent("strategy.py"))
        let executor = NativeScriptExecutor(runner: UnsandboxedScriptRunner(), workDir: setup)
        let outcomes = await executeSuites(
            [SuiteItem(script: "match_rps.sh", tier: .pub, displayName: "match", dependsOn: [], points: 1)],
            timeLimitSeconds: 30, attemptNumber: 1, executor: executor)
        #expect(outcomes.first?.status == .error)
        #expect(outcomes.first?.longResult?.contains("no opponent staged") == true)
    }
}
