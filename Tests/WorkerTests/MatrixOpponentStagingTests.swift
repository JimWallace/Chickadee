// Tests/WorkerTests/MatrixOpponentStagingTests.swift
//
// A matrix job stages its opponents several at a time. What it returns must
// not depend on which opponent finished first: the directories come back in
// `job.opponents` order, and a failure is the one a one-at-a-time loop would
// have thrown, the first failing opponent in that order.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) struct MatrixOpponentStagingTests {

    private struct NoJobPoller: JobPolling {
        func requestJob(activeJobs: Int) async throws(JobPollerError) -> Job? { nil }
    }

    private struct HealthyReporter: Reporting {
        func report(_ report: WorkerExecutionReport) async throws(ReporterError) {}
        func heartbeat(_ payload: WorkerActivityPayload) async throws(ReporterError) {}
    }

    private static func daemon() -> WorkerDaemon {
        let defaults = RunnerDaemonConfig.defaults
        return WorkerDaemon(
            poller: NoJobPoller(),
            reporter: HealthyReporter(),
            runner: UnsandboxedScriptRunner(),
            apiBaseURL: testURL("http://127.0.0.1:9"),
            workerID: "matrix-staging-tests",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            config: RunnerDaemonConfig(
                capabilityDiscoveryEnabled: false,
                testSetupCacheDir: nil,
                networkRetryEnabled: defaults.networkRetryEnabled,
                retryBaseDelayMs: defaults.retryBaseDelayMs,
                retryMaxDelayMs: defaults.retryMaxDelayMs,
                heartbeatRetryMaxAttempts: defaults.heartbeatRetryMaxAttempts,
                resultUploadRetryMaxAttempts: defaults.resultUploadRetryMaxAttempts,
                downloadRetryMaxAttempts: defaults.downloadRetryMaxAttempts,
                minFreeDiskMB: 0,
                makeTimeoutSeconds: defaults.makeTimeoutSeconds))
    }

    private static func job(opponents: [JobOpponent]) -> Job {
        Job(
            submissionID: "sub_matrix", testSetupID: "setup_matrix", attemptNumber: 1,
            submissionURL: testURL("https://x.test/s.zip"),
            testSetupURL: testURL("https://x.test/t.zip"),
            manifest: TestProperties(language: nil), submissionFilename: "strategy.py",
            language: nil,
            opponents: opponents)
    }

    /// A work dir with a test setup holding `bot-<i>.py` for every index in
    /// `present`.
    private static func workspace(present: Range<Int>) throws -> (paths: JobWorkspacePaths, setup: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-matrix-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        let setup = work.appendingPathComponent("setup", isDirectory: true)
        try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true)
        for index in present {
            try "print(\(index))\n".write(
                to: setup.appendingPathComponent("bot-\(index).py"), atomically: true, encoding: .utf8)
        }
        let paths = JobWorkspacePaths(
            tempRoot: root, workDir: work,
            submissionZip: work.appendingPathComponent("submission.zip"),
            submissionDir: work.appendingPathComponent("submission", isDirectory: true))
        return (paths, setup)
    }

    private static func opponent(_ supportFile: String) -> JobOpponent {
        JobOpponent(
            supportFile: supportFile,
            matchSeed: JobOpponent.matchSeed(
                submissionID: "sub_matrix", opponentIdentity: JobOpponent.supportFileIdentity(supportFile)))
    }

    /// More opponents than are staged at once, so the window refills.
    private static let count = WorkerDaemon.opponentStagingWidth * 3 + 1

    @Test func theDirectoriesComeBackInOpponentOrder() async throws {
        let (paths, setup) = try Self.workspace(present: 0..<Self.count)
        defer { try? FileManager.default.removeItem(at: paths.tempRoot) }
        let job = Self.job(opponents: (0..<Self.count).map { Self.opponent("bot-\($0).py") })

        let staged = try await Self.daemon().stageOpponents(job: job, paths: paths, testSetupDir: setup)

        #expect(staged.single == nil)
        #expect(staged.matrix == (0..<Self.count).map { opponentDirectory(workDir: paths.workDir, index: $0) })
        for (index, directory) in staged.matrix.enumerated() {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("bot-\(index).py").path))
        }
    }

    /// Two opponents fail, with different errors. The one earlier in the
    /// list is the job's error, whichever of the two finished first.
    @Test(arguments: [(3, 17), (17, 3)])
    func theFirstFailureInOpponentOrderIsTheError(missingIndex: Int, notBareIndex: Int) async throws {
        let (paths, setup) = try Self.workspace(present: 0..<Self.count)
        defer { try? FileManager.default.removeItem(at: paths.tempRoot) }
        let opponents = (0..<Self.count).map { index in
            switch index {
            case missingIndex: Self.opponent("absent-\(index).py")
            case notBareIndex: Self.opponent("../bot-\(index).py")
            default: Self.opponent("bot-\(index).py")
            }
        }

        let error = await #expect(throws: WorkerDaemonError.self) {
            _ = try await Self.daemon().stageOpponents(
                job: Self.job(opponents: opponents), paths: paths, testSetupDir: setup)
        }

        switch error {
        case .opponentFileMissing(let name)?:
            #expect(missingIndex < notBareIndex)
            #expect(name == "absent-\(missingIndex).py")
        case .opponentFileNotBare(let name)?:
            #expect(notBareIndex < missingIndex)
            #expect(name == "../bot-\(notBareIndex).py")
        default:
            Issue.record("expected the first failing opponent's error, got \(String(describing: error))")
        }
    }
}
