// Tests/WorkerTests/OpponentStagingTests.swift
//
// The worker half of the opponent primitive (docs/class-activities.md, "Runner
// contract"): what gets staged where, the environment a match script sees,
// the loud failures, the build capability — and one real match, the
// rock-paper-scissors fixture played through `executeSuites` with the exact
// environment the daemon sets.

import ChickadeeTestSupport
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
    @Test func anOrdinaryJobStagesNothing() async throws {
        let work = try Self.makeDir("plain")
        defer { try? FileManager.default.removeItem(at: work) }
        let job = try Self.job(opponent: nil)
        let staged = try await stageOpponentWorkspace(job: job, workDir: work, testSetupDir: work)
        #expect(staged == nil)
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("opponent").path))
        #expect(opponentScriptEnvironment(job: job, opponentDir: nil).isEmpty)
    }

    /// The bot lands under its own name in `<work>/opponent/`, outside the
    /// test-setup directory, and both env keys point the script at it.
    @Test func theSupportFileIsStagedUnderItsOwnNameBesideTheSetup() async throws {
        let work = try Self.makeDir("stage")
        defer { try? FileManager.default.removeItem(at: work) }
        let setup = work.appendingPathComponent("setup", isDirectory: true)
        try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true)
        try "print('rock')\n".write(to: setup.appendingPathComponent("bot.py"), atomically: true, encoding: .utf8)

        let job = try Self.job(opponent: JobOpponent(supportFile: "bot.py", matchSeed: Self.seed))
        let staged = try #require(
            try await stageOpponentWorkspace(job: job, workDir: work, testSetupDir: setup))
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
    @Test func aMatchWithNoStageableOpponentFailsLoudly() async throws {
        let work = try Self.makeDir("refuse")
        defer { try? FileManager.default.removeItem(at: work) }

        let unchosen = try Self.job(opponent: JobOpponent(supportFile: nil, matchSeed: Self.seed))
        await #expect(throws: WorkerDaemonError.self) {
            try await stageOpponentWorkspace(job: unchosen, workDir: work, testSetupDir: work)
        }
        do {
            _ = try await stageOpponentWorkspace(job: unchosen, workDir: work, testSetupDir: work)
        } catch let error as WorkerDaemonError {
            #expect(error.errorDescription?.contains("no opponent file is chosen") == true)
        }

        let missing = try Self.job(opponent: JobOpponent(supportFile: "ghost.py", matchSeed: Self.seed))
        do {
            _ = try await stageOpponentWorkspace(job: missing, workDir: work, testSetupDir: work)
            Issue.record("a missing opponent file must throw")
        } catch let error as WorkerDaemonError {
            #expect(error.errorDescription?.contains("ghost.py") == true)
            #expect(error.errorDescription?.contains("not in the test setup") == true)
        }

        let traversal = try Self.job(
            opponent: JobOpponent(supportFile: "../secret.py", matchSeed: Self.seed))
        do {
            _ = try await stageOpponentWorkspace(job: traversal, workDir: work, testSetupDir: work)
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
        let opponentDir = try #require(
            try await stageOpponentWorkspace(job: job, workDir: work, testSetupDir: setup))
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

    // MARK: - A submission opponent (king of the hill, slice 3)

    /// The champion's raw upload lands under its submitted name, a notebook
    /// among it is extracted to source, and the module hint names the
    /// opponent's module — the same shape the challenger's workspace gets.
    @Test func aSubmissionOpponentIsStagedLikeTheChallengersUpload() async throws {
        let work = try Self.makeDir("champ")
        defer { try? FileManager.default.removeItem(at: work) }
        let download = work.appendingPathComponent("opponent-submission.bin")
        let notebook = """
            {"nbformat":4,"nbformat_minor":5,"metadata":{"kernelspec":{"name":"python3"}},\
            "cells":[{"cell_type":"code","metadata":{},"source":["print('rock')\\n"]}]}
            """
        try notebook.write(to: download, atomically: true, encoding: .utf8)
        let job = try Self.job(
            opponent: JobOpponent(
                supportFile: nil, matchSeed: Self.seed, submissionID: "sub_champ",
                submissionURL: testURL("https://x.test/c"),
                submissionFilename: "strategy.ipynb"))
        let staged = try #require(
            try await stageOpponentWorkspace(
                job: job, workDir: work, testSetupDir: work, downloadedSubmission: download))
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: staged.appendingPathComponent("strategy.ipynb").path))
        #expect(fm.fileExists(atPath: staged.appendingPathComponent("strategy.py").path))
        let hint = try String(
            contentsOf: staged.appendingPathComponent(".chickadee_student_module"), encoding: .utf8)
        #expect(hint == "strategy.py")
        #expect(opponentScriptEnvironment(job: job, opponentDir: staged)[OpponentEnvironment.directory] == staged.path)
    }

    /// A submission opponent whose download never landed fails the job with
    /// the fix named, rather than grading a match against nobody.
    @Test func aMissingOpponentDownloadFailsLoudly() async throws {
        let work = try Self.makeDir("champ-missing")
        defer { try? FileManager.default.removeItem(at: work) }
        let job = try Self.job(
            opponent: JobOpponent(
                supportFile: nil, matchSeed: Self.seed, submissionID: "sub_champ",
                submissionURL: testURL("https://x.test/c"),
                submissionFilename: "strategy.py"))
        do {
            _ = try await stageOpponentWorkspace(job: job, workDir: work, testSetupDir: work, downloadedSubmission: nil)
            Issue.record("a missing opponent download must throw")
        } catch let error as WorkerDaemonError {
            #expect(error.errorDescription?.contains("sub_champ") == true)
            #expect(error.errorDescription?.contains("nobody to play") == true)
        }
    }

    /// This build advertises both staging capabilities.
    @Test func thisBuildAdvertisesTheSubmissionOpponentCapability() {
        #expect(RunnerProfileDetector.buildCapabilities.contains(.activityOpponentSubmission))
    }

    // MARK: - A matrix of opponents (slice 4)

    /// This build advertises the matrix capability too, and every source's
    /// token is one this build carries.
    @Test func thisBuildAdvertisesTheMatrixCapability() {
        #expect(RunnerProfileDetector.buildCapabilities.contains(.activityMatrix))
        #expect(RunnerCapability.activityMatrix.name == "activity-matrix")
        for source in ActivityOpponentSource.allCases {
            guard let token = source.requiredRunnerCapability else { continue }
            #expect(RunnerProfileDetector.buildCapabilities.contains(token), "\(source) needs \(token.name)")
        }
    }

    /// Each opponent of a matrix job gets its own download and its own
    /// directory, distinct from the single-opponent paths and from each other.
    @Test func matrixOpponentsGetDistinctPaths() {
        let work = URL(fileURLWithPath: "/work")
        #expect(opponentDirectory(workDir: work).lastPathComponent == "opponent")
        #expect(opponentDirectory(workDir: work, index: 0).lastPathComponent == "opponent-0")
        #expect(opponentDirectory(workDir: work, index: 1).lastPathComponent == "opponent-1")
        #expect(opponentDownloadDestination(workDir: work).lastPathComponent == "opponent-submission.bin")
        #expect(opponentDownloadDestination(workDir: work, index: 2).lastPathComponent == "opponent-2-submission.bin")
    }

    /// Two opponents staged side by side, each under its own index, each
    /// with an environment pointing the script at its own directory and seed.
    @Test func twoOpponentsAreStagedSideBySide() async throws {
        let work = try Self.makeDir("matrix")
        defer { try? FileManager.default.removeItem(at: work) }
        let setup = work.appendingPathComponent("setup", isDirectory: true)
        try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true)
        try "print('rock')\n".write(to: setup.appendingPathComponent("bot.py"), atomically: true, encoding: .utf8)
        let raw = work.appendingPathComponent("mate.bin")
        try "def play(_):\n    return 'paper'\n".write(to: raw, atomically: true, encoding: .utf8)

        let bot = JobOpponent(supportFile: "bot.py", matchSeed: Self.seed)
        let mate = JobOpponent(
            supportFile: nil,
            matchSeed: JobOpponent.matchSeed(submissionID: "sub_match", opponentIdentity: "submission:m"),
            submissionID: "m", submissionURL: testURL("https://x.test/m.bin"), submissionFilename: "strategy.py")
        let botDir = try await stageOpponent(
            bot, manifest: TestProperties(), into: opponentDirectory(workDir: work, index: 0),
            testSetupDir: setup, downloadedSubmission: nil)
        let mateDir = try await stageOpponent(
            mate, manifest: TestProperties(), into: opponentDirectory(workDir: work, index: 1),
            testSetupDir: setup, downloadedSubmission: raw)
        #expect(botDir.lastPathComponent == "opponent-0")
        #expect(mateDir.lastPathComponent == "opponent-1")
        #expect(FileManager.default.fileExists(atPath: botDir.appendingPathComponent("bot.py").path))
        #expect(FileManager.default.fileExists(atPath: mateDir.appendingPathComponent("strategy.py").path))
        #expect(!FileManager.default.fileExists(atPath: botDir.appendingPathComponent("strategy.py").path))

        let botEnv = opponentScriptEnvironment(opponent: bot, opponentDir: botDir)
        let mateEnv = opponentScriptEnvironment(opponent: mate, opponentDir: mateDir)
        #expect(botEnv[OpponentEnvironment.directory] == botDir.path)
        #expect(mateEnv[OpponentEnvironment.directory] == mateDir.path)
        #expect(botEnv[OpponentEnvironment.matchSeed] != mateEnv[OpponentEnvironment.matchSeed])
    }

    /// The fixture match played against a staged champion submission: the
    /// champion's `strategy.py` is found by the same name the bot was.
    @Test func theFixtureMatchIsGradedAgainstAStagedChampion() async throws {
        let work = try Self.makeDir("rps-champ")
        defer { try? FileManager.default.removeItem(at: work) }
        let setup = work.appendingPathComponent("setup", isDirectory: true)
        try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true)
        let fm = FileManager.default
        try fm.copyItem(
            at: Self.fixturesDir.appendingPathComponent("match_rps.sh"),
            to: setup.appendingPathComponent("match_rps.sh"))
        try fm.copyItem(
            at: Self.fixturesDir.appendingPathComponent("student_strategy.py"),
            to: setup.appendingPathComponent("strategy.py"))
        let download = work.appendingPathComponent("opponent-submission.bin")
        try fm.copyItem(at: Self.fixturesDir.appendingPathComponent("bot_strategy.py"), to: download)
        let job = try Self.job(
            opponent: JobOpponent(
                supportFile: nil, matchSeed: Self.seed, submissionID: "sub_champ",
                submissionURL: testURL("https://x.test/c"),
                submissionFilename: "strategy.py"))
        let opponentDir = try #require(
            try await stageOpponentWorkspace(
                job: job, workDir: work, testSetupDir: setup, downloadedSubmission: download))
        let executor = NativeScriptExecutor(
            runner: UnsandboxedScriptRunner(), workDir: setup,
            env: opponentScriptEnvironment(job: job, opponentDir: opponentDir))
        let outcomes = await executeSuites(
            [SuiteItem(script: "match_rps.sh", tier: .pub, displayName: "match", dependsOn: [], points: 1)],
            timeLimitSeconds: 30, attemptNumber: 1, executor: executor)
        #expect(outcomes.first?.status == .pass, "stderr: \(outcomes.first?.longResult ?? "")")
        #expect(outcomes.first?.metric == 5)
    }
}
