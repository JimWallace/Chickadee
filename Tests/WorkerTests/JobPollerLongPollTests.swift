import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import chickadee_runner

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The runner's side of the held poll (`WorkerLongPoll`): what the poller asks
/// for, when it reports a held poll, and that the daemon polls again at once
/// after one instead of backing off.
@Suite(.serialized, .timeLimit(.minutes(3))) struct JobPollerLongPollTests {

    private let apiBaseURL = testURL("https://server.test")

    private func makePoller(minimumHeldDuration: Duration = .zero) -> JobPoller {
        JobPoller(
            apiBaseURL: apiBaseURL,
            workerID: "long-poll-worker",
            workerSecret: "test-secret",
            maxConcurrentJobs: 1,
            session: .mocked(),
            minimumHeldDuration: minimumHeldDuration
        )
    }

    private func sentPayload() throws -> WorkerActivityPayload {
        let body = try #require(MockURLProtocol.capturedBodies.last)
        return try JSONDecoder().decode(WorkerActivityPayload.self, from: body)
    }

    // MARK: What the poller asks for

    @Test func daemonPollAsksTheServerToHoldIt() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(204))
            _ = try await makePoller().pollForJob(activeJobs: 0)
            #expect(try sentPayload().longPollSeconds == WorkerLongPoll.requestedHoldSeconds)
        }
    }

    @Test func requestJobAsksForAnImmediateAnswer() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(204))
            _ = try await makePoller().requestJob(activeJobs: 0)
            #expect(try sentPayload().longPollSeconds == nil)
        }
    }

    // MARK: When a 204 counts as held

    @Test func a204WithTheHeldHeaderIsAHeldPoll() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(204, headers: [WorkerLongPoll.heldHeader: "1"]))
            let result = try await makePoller().pollForJob(activeJobs: 0)
            #expect(result.job == nil)
            #expect(result.serverHeldPoll)
        }
    }

    @Test func a204WithoutTheHeaderIsNotHeld() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(204))
            let result = try await makePoller().pollForJob(activeJobs: 0)
            #expect(!result.serverHeldPoll)
        }
    }

    /// A server that is shutting down releases its held polls at once, with
    /// the header. A 204 that fast was not held, so the slot backs off.
    @Test func aFastHeldHeaderIsNotHeld() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(204, headers: [WorkerLongPoll.heldHeader: "1"]))
            let result = try await makePoller(minimumHeldDuration: .seconds(60)).pollForJob(activeJobs: 0)
            #expect(!result.serverHeldPoll)
        }
    }

    // MARK: The daemon after a held poll

    /// Answers every poll with a held 204.
    private actor HeldPoller: JobPolling {
        private(set) var pollCount = 0

        func requestJob(activeJobs: Int) async throws(JobPollerError) -> Job? {
            nil
        }

        func pollForJob(activeJobs: Int) async throws(JobPollerError) -> JobPollResult {
            pollCount += 1
            // A real held poll waits on the server. A short pause keeps this
            // loop from spinning the test's thread.
            try? await Task.sleep(for: .milliseconds(20))
            return JobPollResult(job: nil, serverHeldPoll: true)
        }
    }

    private actor NoOpReporter: Reporting {
        func report(_ report: WorkerExecutionReport) async throws(ReporterError) {}
        func heartbeat(_ payload: WorkerActivityPayload) async throws(ReporterError) {}
    }

    private struct NoOpRunner: ScriptRunner {
        func run(script: URL, workDir: URL, timeLimitSeconds: Int, env: [String: String]) async -> ScriptOutput {
            ScriptOutput(exitCode: 0, stdout: "", stderr: "", executionTimeMs: 1, timedOut: false)
        }
    }

    /// The backoff after an empty poll is at least 60 s here, so a second
    /// poll within the wait proves the daemon skipped it.
    @Test func daemonPollsAgainAtOnceAfterAHeldPoll() async throws {
        let base = RunnerDaemonConfig.defaults
        let config = RunnerDaemonConfig(
            capabilityDiscoveryEnabled: base.capabilityDiscoveryEnabled,
            testSetupCacheDir: nil,
            networkRetryEnabled: true,
            retryBaseDelayMs: 60_000,
            retryMaxDelayMs: 120_000,
            heartbeatRetryMaxAttempts: base.heartbeatRetryMaxAttempts,
            resultUploadRetryMaxAttempts: base.resultUploadRetryMaxAttempts,
            downloadRetryMaxAttempts: base.downloadRetryMaxAttempts,
            minFreeDiskMB: 0,
            makeTimeoutSeconds: base.makeTimeoutSeconds
        )
        let poller = HeldPoller()
        let daemon = WorkerDaemon(
            poller: poller,
            reporter: NoOpReporter(),
            runner: NoOpRunner(),
            apiBaseURL: testURL("http://localhost:8080"),
            workerID: "long-poll-daemon",
            workerSecret: "secret",
            maxConcurrentJobs: 1,
            config: config
        )
        let task = Task { try await daemon.run() }
        defer { task.cancel() }

        let deadline = ContinuousClock.now + .seconds(20)
        while await poller.pollCount < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await poller.pollCount >= 3, "the daemon backed off after a held poll")

        await daemon.drain()
        task.cancel()
    }
}
