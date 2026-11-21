// Tests/WorkerTests/Daemon/RunnerDaemonJobOutcomeTests.swift
//
// What the runner reports back for the job paths that no other suite drove
// end to end: a seeded job, a per-test time limit, a matrix (round robin)
// job, a missing suite script, a failed `make` step, the two poll errors
// that only retry (`unexpectedResponse`, `decodingFailed`), a terminal poll
// error, and a download that arrives but cannot be moved into place.
//
// The server is scripted: a poller hands out the jobs, a reporter records
// the reports, and a local `python3 http.server` (`LocalHTTPTestServer`)
// serves the artifacts on 127.0.0.1. The script runner records each call and
// answers from a rule, so a test reads exactly what each script received.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(3))) final class RunnerDaemonJobOutcomeTests {

    /// One scripted answer to a poll.
    private enum PollStep: Sendable {
        case job(Job)
        case error(JobPollerError)
    }

    /// Hands out `steps` in order, then answers "no job" for ever.
    private actor ScriptedPoller: JobPolling {
        private var steps: [PollStep]
        private(set) var requestCount = 0

        init(_ steps: [PollStep]) {
            self.steps = steps
        }

        func requestJob(activeJobs: Int) async throws(JobPollerError) -> Job? {
            requestCount += 1
            guard !steps.isEmpty else { return nil }
            switch steps.removeFirst() {
            case .job(let job): return job
            case .error(let error): throw error
            }
        }
    }

    /// Records each report, and resumes a waiter when the report it waits
    /// for arrives, so no test sleeps to let a job finish.
    private actor RecordingReporter: Reporting {
        private var reports: [WorkerExecutionReport] = []
        private var waiters: [(count: Int, continuation: CheckedContinuation<[WorkerExecutionReport], Never>)] = []

        func report(_ report: WorkerExecutionReport) async throws(ReporterError) {
            reports.append(report)
            let ready = waiters.filter { $0.count <= reports.count }
            waiters.removeAll { $0.count <= reports.count }
            for waiter in ready { waiter.continuation.resume(returning: reports) }
        }

        func heartbeat(_ payload: WorkerActivityPayload) async throws(ReporterError) {}

        func waitForReports(_ count: Int) async -> [WorkerExecutionReport] {
            if reports.count >= count { return reports }
            return await withCheckedContinuation { continuation in
                waiters.append((count, continuation))
            }
        }
    }

    /// What one script call received.
    private struct ScriptCall: Sendable {
        let script: String
        let timeLimitSeconds: Int
        let env: [String: String]
    }

    /// Records every script call and answers from `rule`. The `make` step
    /// keeps the protocol's default, so it runs the real `make`.
    private actor RecordingRunner: ScriptRunner {
        private let rule: @Sendable (_ script: String, _ env: [String: String]) -> ScriptOutput
        private(set) var calls: [ScriptCall] = []

        init(rule: @escaping @Sendable (_ script: String, _ env: [String: String]) -> ScriptOutput) {
            self.rule = rule
        }

        func run(script: URL, workDir: URL, timeLimitSeconds: Int, env: [String: String]) async -> ScriptOutput {
            let name = script.lastPathComponent
            calls.append(ScriptCall(script: name, timeLimitSeconds: timeLimitSeconds, env: env))
            return rule(name, env)
        }
    }

    private static func output(exitCode: Int32, stdout: String = "") -> ScriptOutput {
        ScriptOutput(exitCode: exitCode, stdout: stdout, stderr: "", executionTimeMs: 1, timedOut: false)
    }

    private static let passEveryScript: @Sendable (String, [String: String]) -> ScriptOutput = { _, _ in
        output(exitCode: 0)
    }

    let root: URL
    let served: URL
    let cacheRoot: URL
    let workRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-daemon-outcome-\(UUID().uuidString)", isDirectory: true)
        served = root.appendingPathComponent("served", isDirectory: true)
        cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        workRoot = root.appendingPathComponent("work", isDirectory: true)
        for directory in [served, cacheRoot, workRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func daemon(
        poller: any JobPolling, reporter: any Reporting, runner: any ScriptRunner
    ) -> WorkerDaemon {
        let defaults = RunnerDaemonConfig.defaults
        return WorkerDaemon(
            poller: poller,
            reporter: reporter,
            runner: runner,
            apiBaseURL: testURL("http://127.0.0.1:9"),
            workerID: "daemon-outcome-tests",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            downloadRetryPolicy: RunnerRetryPolicy(enabled: true, maxAttempts: 2, baseDelayMs: 10, maxDelayMs: 20),
            testSetupCache: TestSetupCache(cacheRoot: cacheRoot),
            config: RunnerDaemonConfig(
                capabilityDiscoveryEnabled: false,
                testSetupCacheDir: nil,
                networkRetryEnabled: true,
                retryBaseDelayMs: 10,
                retryMaxDelayMs: 20,
                heartbeatRetryMaxAttempts: 2,
                resultUploadRetryMaxAttempts: 2,
                downloadRetryMaxAttempts: 2,
                minFreeDiskMB: 0,
                makeTimeoutSeconds: defaults.makeTimeoutSeconds),
            workRoot: workRoot)
    }

    /// Serves a test setup zip of `files` and a raw `solution.py`, and
    /// returns a job that points at both.
    private func servedJob(
        name: String,
        files: [String: String],
        manifest: TestProperties,
        assignmentSeed: String? = nil,
        opponents: [JobOpponent]? = nil,
        port: Int
    ) async throws -> Job {
        let source = root.appendingPathComponent("setup-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (file, contents) in files {
            try contents.write(to: source.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try await createZipArchive(sourceDir: source, outputPath: served.appendingPathComponent("\(name).zip").path)
        try "x = 1\n".write(
            to: served.appendingPathComponent("\(name)-solution.py"), atomically: true, encoding: .utf8)
        return Job(
            submissionID: "sub_\(name)",
            testSetupID: "setup_\(name)_\(UUID().uuidString)",
            attemptNumber: 1,
            submissionURL: testURL("http://127.0.0.1:\(port)/\(name)-solution.py"),
            testSetupURL: testURL("http://127.0.0.1:\(port)/\(name).zip"),
            manifest: manifest,
            submissionFilename: "solution.py",
            assignmentSeed: assignmentSeed,
            language: nil,
            opponents: opponents)
    }

    /// Runs the daemon until `count` reports arrive, then drains it and
    /// waits for `run()` to return.
    private func runUntilReported(
        _ count: Int, poller: ScriptedPoller, runner: any ScriptRunner
    ) async throws -> [WorkerExecutionReport] {
        let reporter = RecordingReporter()
        let daemon = daemon(poller: poller, reporter: reporter, runner: runner)
        let task = Task { try await daemon.run() }
        let reports = await reporter.waitForReports(count)
        await daemon.drain()
        try await task.value
        return reports
    }

    // MARK: - Suite execution

    /// The assignment seed reaches every script as `CHICKADEE_ASSIGNMENT_SEED`,
    /// and a test with its own time limit runs under that limit, not the
    /// assignment's. Both tests pass, so the build passes.
    @Test func aSeededJobPassesTheSeedAndEachTimeLimitToItsScripts() async throws {
        let server = try await LocalHTTPTestServer.staticFiles(directory: served)
        defer { server.stop() }
        let manifest = TestProperties(
            testSuites: [
                TestSuiteEntry(tier: .pub, script: "slow.sh", timeLimitSeconds: 7),
                TestSuiteEntry(tier: .release, script: "fast.sh"),
            ],
            timeLimitSeconds: 3, language: nil)
        let job = try await servedJob(
            name: "seeded", files: ["slow.sh": "exit 0\n", "fast.sh": "exit 0\n"], manifest: manifest,
            assignmentSeed: "c0ffee", port: server.port)
        let runner = RecordingRunner(rule: Self.passEveryScript)

        let reports = try await runUntilReported(1, poller: ScriptedPoller([.job(job)]), runner: runner)

        let report = try #require(reports.first)
        #expect(report.collection.submissionID == "sub_seeded")
        #expect(report.collection.buildStatus == .passed)
        #expect(report.collection.outcomes.map(\.status) == [.pass, .pass])
        #expect(report.collection.passCount == 2)
        #expect(report.matches == nil)
        let calls = await runner.calls
        #expect(calls.map(\.script) == ["slow.sh", "fast.sh"])
        #expect(calls.map(\.timeLimitSeconds) == [7, 3])
        #expect(calls.allSatisfy { $0.env["CHICKADEE_ASSIGNMENT_SEED"] == "c0ffee" })
    }

    /// An empty seed is the same as no seed: the variable is not set.
    @Test func anEmptySeedIsNotPassedToTheScripts() async throws {
        let server = try await LocalHTTPTestServer.staticFiles(directory: served)
        defer { server.stop() }
        let manifest = TestProperties(testSuites: [TestSuiteEntry(tier: .pub, script: "t.sh")], language: nil)
        let job = try await servedJob(
            name: "emptyseed", files: ["t.sh": "exit 0\n"], manifest: manifest, assignmentSeed: "",
            port: server.port)
        let runner = RecordingRunner(rule: Self.passEveryScript)

        let reports = try await runUntilReported(1, poller: ScriptedPoller([.job(job)]), runner: runner)

        #expect(reports.first?.collection.buildStatus == .passed)
        let calls = await runner.calls
        #expect(calls.count == 1)
        #expect(calls.first?.env["CHICKADEE_ASSIGNMENT_SEED"] == nil)
    }

    /// A matrix job runs the suite once per opponent, each with that
    /// opponent's directory and match seed. The runs fold into one outcome,
    /// and the report carries one match row per opponent.
    @Test func aMatrixJobRunsTheSuiteOncePerOpponentAndReportsEachMatch() async throws {
        let server = try await LocalHTTPTestServer.staticFiles(directory: served)
        defer { server.stop() }
        let manifest = TestProperties(testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")], language: nil)
        let opponents = [
            JobOpponent(supportFile: "bot-a.py", matchSeed: "seed-a"),
            JobOpponent(supportFile: "bot-b.py", matchSeed: "seed-b"),
        ]
        let job = try await servedJob(
            name: "matrix",
            files: ["match.sh": "exit 0\n", "bot-a.py": "a = 1\n", "bot-b.py": "b = 1\n"],
            manifest: manifest, opponents: opponents, port: server.port)
        // The challenger beats bot A and loses to bot B.
        let runner = RecordingRunner { _, env in
            env["CHICKADEE_MATCH_SEED"] == "seed-a"
                ? Self.output(exitCode: 0, stdout: #"{"score": 1, "metric": 3}"#)
                : Self.output(exitCode: 1, stdout: #"{"score": 0, "metric": 1}"#)
        }

        let reports = try await runUntilReported(1, poller: ScriptedPoller([.job(job)]), runner: runner)

        let report = try #require(reports.first)
        #expect(report.collection.buildStatus == .passed)
        let outcome = try #require(report.collection.outcomes.first)
        #expect(report.collection.outcomes.count == 1)
        #expect(outcome.score == 0.5)
        #expect(outcome.metric == 4)
        #expect(outcome.status == .pass)
        let matches = try #require(report.matches)
        #expect(matches.map(\.seed) == ["seed-a", "seed-b"])
        #expect(matches.map(\.won) == [true, false])
        #expect(matches.map(\.opponentIdentity) == opponents.map(\.identity))

        let calls = await runner.calls
        #expect(calls.map { $0.env["CHICKADEE_MATCH_SEED"] } == ["seed-a", "seed-b"])
        let directories = calls.compactMap { $0.env["CHICKADEE_OPPONENT_DIR"] }
        #expect(directories.count == 2)
        #expect(Set(directories).count == 2)
    }

    /// A suite script that the test setup does not contain gets no outcome;
    /// the scripts that exist still run and report.
    @Test func aMissingScriptIsLeftOutOfTheReport() async throws {
        let server = try await LocalHTTPTestServer.staticFiles(directory: served)
        defer { server.stop() }
        let manifest = TestProperties(
            testSuites: [
                TestSuiteEntry(tier: .pub, script: "absent.sh"),
                TestSuiteEntry(tier: .pub, script: "present.sh"),
            ],
            language: nil)
        let job = try await servedJob(
            name: "missing", files: ["present.sh": "exit 0\n"], manifest: manifest, port: server.port)
        let runner = RecordingRunner { _, _ in Self.output(exitCode: 1) }

        let reports = try await runUntilReported(1, poller: ScriptedPoller([.job(job)]), runner: runner)

        let report = try #require(reports.first)
        #expect(report.collection.buildStatus == .passed)
        #expect(
            report.collection.outcomes.map(\.testName)
                == [runnerOutcomeTestName(displayName: nil, script: "present.sh")])
        #expect(report.collection.outcomes.map(\.status) == [.fail])
        #expect(report.collection.totalTests == 1)
        #expect(await runner.calls.map(\.script) == ["present.sh"])
    }

    /// When no suite script exists, nothing ran, so the build fails at the
    /// collection level with no outcomes.
    @Test func aSuiteWithNoScriptsFailsTheBuild() async throws {
        let server = try await LocalHTTPTestServer.staticFiles(directory: served)
        defer { server.stop() }
        let manifest = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "absent.sh")], language: nil)
        let job = try await servedJob(
            name: "noscripts", files: ["readme.txt": "none\n"], manifest: manifest, port: server.port)
        let runner = RecordingRunner(rule: Self.passEveryScript)

        let reports = try await runUntilReported(1, poller: ScriptedPoller([.job(job)]), runner: runner)

        let report = try #require(reports.first)
        #expect(report.collection.buildStatus == .failed)
        #expect(report.collection.outcomes.isEmpty)
        #expect(report.collection.totalTests == 0)
        #expect(await runner.calls.isEmpty)
    }

    /// A `make` step that exits non-zero fails the build at the collection
    /// level: no test runs, the outcomes are empty, and the compiler output
    /// carries what `make` printed.
    @Test(.requiresMake) func aFailedMakeStepReportsAFailedBuildWithNoOutcomes() async throws {
        let server = try await LocalHTTPTestServer.staticFiles(directory: served)
        defer { server.stop() }
        let manifest = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "t.sh")],
            makefile: MakefileConfig(target: nil), language: nil)
        let job = try await servedJob(
            name: "makefail",
            files: ["t.sh": "exit 0\n", "Makefile": "all:\n\t@echo undefined symbol widget >&2\n\t@false\n"],
            manifest: manifest, port: server.port)
        let runner = RecordingRunner(rule: Self.passEveryScript)

        let reports = try await runUntilReported(1, poller: ScriptedPoller([.job(job)]), runner: runner)

        let report = try #require(reports.first)
        #expect(report.collection.submissionID == "sub_makefail")
        #expect(report.collection.buildStatus == .failed)
        #expect(report.collection.outcomes.isEmpty)
        #expect(report.collection.errorCount == 1)
        let compilerOutput = try #require(report.collection.compilerOutput)
        #expect(compilerOutput.contains("makeFailed"))
        #expect(compilerOutput.contains("undefined symbol widget"))
        #expect(await runner.calls.isEmpty)
    }

    // MARK: - Poll errors

    /// A non-HTTP answer and an undecodable job are retried, not fatal: the
    /// slot keeps polling and grades the job the next poll hands out.
    @Test func aPollThatAnswersBadlyIsRetriedAndTheNextJobIsGraded() async throws {
        let server = try await LocalHTTPTestServer.staticFiles(directory: served)
        defer { server.stop() }
        let manifest = TestProperties(testSuites: [TestSuiteEntry(tier: .pub, script: "t.sh")], language: nil)
        let job = try await servedJob(
            name: "afterretry", files: ["t.sh": "exit 0\n"], manifest: manifest, port: server.port)
        let poller = ScriptedPoller([
            .error(.unexpectedResponse),
            .error(.decodingFailed(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "skew")))),
            .job(job),
        ])
        let runner = RecordingRunner(rule: Self.passEveryScript)

        let reports = try await runUntilReported(1, poller: poller, runner: runner)

        #expect(reports.map(\.collection.submissionID) == ["sub_afterretry"])
        #expect(reports.first?.collection.buildStatus == .passed)
        #expect(await poller.requestCount >= 3)
    }

    /// An HTTP status that is not retryable on a poll (404) stops the loop:
    /// `run()` rethrows it, and no job is graded.
    @Test func aTerminalPollStatusStopsTheRunner() async throws {
        let poller = ScriptedPoller([.error(.httpError(404, "no such route"))])
        let reporter = RecordingReporter()
        let runner = RecordingRunner(rule: Self.passEveryScript)
        let daemon = daemon(poller: poller, reporter: reporter, runner: runner)

        do {
            try await daemon.run()
            Issue.record("a terminal poll status must stop run()")
        } catch JobPollerError.httpError(let status, let body) {
            #expect(status == 404)
            #expect(body == "no such route")
        }
        #expect(await poller.requestCount == 1)
        #expect(await runner.calls.isEmpty)
    }

    // MARK: - Downloads

    // No test here for a non-HTTP response (`downloadFailed`). No URL gives
    // one on both platforms: on Linux, FoundationNetworking throws
    // `URLError(.unsupportedURL)` for a file URL, which `download` retries,
    // and it traps the process for a data URL.

    /// A download that arrives but cannot be moved into place fails with the
    /// file-system error, not as a network failure.
    @Test func aDownloadThatCannotBeMovedIntoPlaceFailsWithTheFileError() async throws {
        let server = try await LocalHTTPTestServer.staticFiles(directory: served)
        defer { server.stop() }
        try "payload\n".write(to: served.appendingPathComponent("artifact.txt"), atomically: true, encoding: .utf8)
        let destination = root.appendingPathComponent("no-such-dir/artifact.txt")
        let daemon = daemon(
            poller: ScriptedPoller([]), reporter: RecordingReporter(),
            runner: RecordingRunner(rule: Self.passEveryScript))

        do {
            try await daemon.download(
                url: testURL("http://127.0.0.1:\(server.port)/artifact.txt"), to: destination,
                stage: .downloadSubmission)
            Issue.record("a move into a missing directory must fail the download")
        } catch {
            #expect(!(error is WorkerDaemonError))
            #expect(!(error is URLError))
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
