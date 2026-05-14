import Fluent
import Foundation
import XCTVapor
import XCTest

@testable import Core
@testable import chickadee_server

final class ObservabilityTests: XCTestCase {
    private var app: Application!
    private let workerSecret = "observability-secret"

    override func setUp() async throws {
        app = try await makeTestApp(prefix: "chickadee-obs")
        app.workerSecretStore = WorkerSecretStore(initialOverride: workerSecret)
    }

    override func tearDown() async throws {
        try await app.tearDownTestApp()
    }

    func testQueueWaitMetricCalculationPersistsExpectedMilliseconds() async throws {
        let (_, submission) = try await makeSubmission(submissionID: "sub_queue_wait")
        let enqueuedAt = Date(timeIntervalSince1970: 1_000)
        let assignedAt = Date(timeIntervalSince1970: 1_003.5)

        submission.submittedAt = enqueuedAt
        try await submission.update(on: app.db)
        await app.diagnostics.recordSubmissionCreated(submission: submission, on: app.db, logger: app.logger)

        submission.workerID = "runner-queue"
        submission.assignedAt = assignedAt
        submission.status = "assigned"
        try await submission.update(on: app.db)
        await app.diagnostics.recordJobAssigned(submission: submission, on: app.db, logger: app.logger)

        let metric = try await JobExecutionMetric.query(on: app.db)
            .filter(\.$submissionID == "sub_queue_wait")
            .first()
        XCTAssertEqual(metric?.queueWaitMs, 3500)
    }

    func testExecutionDurationAndFinalStatusPersistence() async throws {
        let (_, submission) = try await makeSubmission(submissionID: "sub_exec_metric")
        let enqueuedAt = Date(timeIntervalSince1970: 2_000)
        let assignedAt = Date(timeIntervalSince1970: 2_002)
        let startedAt = Date(timeIntervalSince1970: 2_003)
        let completedAt = Date(timeIntervalSince1970: 2_006.25)

        submission.submittedAt = enqueuedAt
        submission.workerID = "runner-exec"
        submission.assignedAt = assignedAt
        submission.status = "assigned"
        try await submission.update(on: app.db)

        await app.diagnostics.recordSubmissionCreated(submission: submission, on: app.db, logger: app.logger)
        await app.diagnostics.recordJobAssigned(submission: submission, on: app.db, logger: app.logger)

        let collection = TestOutcomeCollection(
            submissionID: try submission.requireID(),
            testSetupID: submission.testSetupID,
            attemptNumber: submission.attemptNumber ?? 1,
            buildStatus: .passed,
            compilerOutput: nil,
            outcomes: [
                TestOutcome(
                    testName: "public.testOne",
                    testClass: nil,
                    tier: .pub,
                    status: .error,
                    shortResult: "traceback",
                    longResult: "stack",
                    executionTimeMs: 3250,
                    memoryUsageBytes: nil,
                    attemptNumber: 1,
                    isFirstPassSuccess: false
                )
            ],
            totalTests: 1,
            passCount: 0,
            failCount: 0,
            errorCount: 1,
            timeoutCount: 0,
            executionTimeMs: 3250,
            jobStartedAt: startedAt,
            runnerVersion: "runner-test/1.0",
            timestamp: completedAt
        )

        await app.diagnostics.recordWorkerResult(
            collection: collection,
            submission: submission,
            on: app.db,
            logger: app.logger
        )

        let metric = try await JobExecutionMetric.query(on: app.db)
            .filter(\.$submissionID == "sub_exec_metric")
            .first()
        XCTAssertEqual(metric?.executionMs, 3250)
        XCTAssertEqual(metric?.totalProcessingMs, 6250)
        XCTAssertEqual(metric?.finalStatus, JobFinalStatus.error.rawValue)
    }

    func testWrappedExecutionReportPersistsStageTimingMetrics() async throws {
        let (_, submission) = try await makeSubmission(submissionID: "sub_stage_metrics")
        submission.submittedAt = Date(timeIntervalSince1970: 3_000)
        submission.workerID = "runner-stage"
        submission.assignedAt = Date(timeIntervalSince1970: 3_001)
        submission.status = "assigned"
        try await submission.update(on: app.db)

        await app.diagnostics.recordSubmissionCreated(submission: submission, on: app.db, logger: app.logger)
        await app.diagnostics.recordJobAssigned(submission: submission, on: app.db, logger: app.logger)

        let collection = TestOutcomeCollection(
            submissionID: try submission.requireID(),
            testSetupID: submission.testSetupID,
            attemptNumber: submission.attemptNumber ?? 1,
            buildStatus: .passed,
            compilerOutput: nil,
            outcomes: [],
            totalTests: 0,
            passCount: 0,
            failCount: 0,
            errorCount: 0,
            timeoutCount: 0,
            executionTimeMs: 250,
            jobStartedAt: Date(timeIntervalSince1970: 3_002),
            runnerVersion: "runner-test/1.0",
            timestamp: Date(timeIntervalSince1970: 3_003)
        )
        let diagnostics = WorkerExecutionDiagnostics(
            runnerID: "runner-stage",
            startedAt: Date(timeIntervalSince1970: 3_002),
            finishedAt: Date(timeIntervalSince1970: 3_003),
            finalStatus: "passed",
            timedOut: false,
            exitCode: 0,
            terminationReason: nil,
            peakRSSBytes: nil,
            wallClockMs: 250,
            childProcessCount: nil,
            stdoutBytes: nil,
            stderrBytes: nil,
            stageTimings: WorkerExecutionStageTimings(
                workdirSetupMs: 10,
                submissionDirSetupMs: 15,
                submissionDownloadMs: 20,
                testSetupAcquireMs: 25,
                submissionUnpackMs: 30,
                starterCleanupMs: 5,
                submissionPrepareMs: 40,
                makeStepMs: 50,
                runtimeHelperSetupMs: 12,
                testExecutionMs: 250
            )
        )

        await app.diagnostics.recordWorkerExecutionReport(
            collection: collection,
            diagnostics: diagnostics,
            on: app.db,
            logger: app.logger
        )

        let metric = try await JobExecutionMetric.query(on: app.db)
            .filter(\.$submissionID == "sub_stage_metrics")
            .first()
        XCTAssertEqual(metric?.workdirSetupMs, 10)
        XCTAssertEqual(metric?.submissionDirSetupMs, 15)
        XCTAssertEqual(metric?.submissionDownloadMs, 20)
        XCTAssertEqual(metric?.testSetupAcquireMs, 25)
        XCTAssertEqual(metric?.submissionUnpackMs, 30)
        XCTAssertEqual(metric?.starterCleanupMs, 5)
        XCTAssertEqual(metric?.submissionPrepareMs, 40)
        XCTAssertEqual(metric?.makeStepMs, 50)
        XCTAssertEqual(metric?.runtimeHelperSetupMs, 12)
        XCTAssertEqual(metric?.testExecutionMs, 250)
    }

    func testWorkerHeartbeatUpdatesRunnerSnapshot() async throws {
        let payload = WorkerActivityPayload(
            workerID: "runner-heartbeat",
            hostname: "host-a",
            runnerVersion: "runner/1.2.3",
            maxConcurrentJobs: 4,
            activeJobs: 2,
            profile: RunnerCapabilityProfile(
                platform: "linux",
                architecture: "x86_64",
                languageVersions: [LanguageVersion(language: "python", version: "3.11.8")],
                capabilities: [RunnerCapability(name: "numpy")]
            )
        )
        let body = try encodedBody(payload)
        let path = "/api/v1/worker/heartbeat"

        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers = workerHMACHeaders(
                    method: .POST,
                    path: path,
                    body: body,
                    workerSecret: self.workerSecret,
                    workerID: payload.workerID
                )
                req.body = body
            },
            afterResponse: { response in
                XCTAssertEqual(response.status, .ok)
            })

        let snapshot = try await RunnerSnapshot.query(on: app.db)
            .filter(\.$runnerID == "runner-heartbeat")
            .sort(\.$recordedAt, .descending)
            .first()
        XCTAssertEqual(snapshot?.activeJobs, 2)
        XCTAssertEqual(snapshot?.maxJobs, 4)
        XCTAssertEqual(snapshot?.availableCapacity, 2)
        XCTAssertNotNil(snapshot?.lastHeartbeatAt)

        let runnerProfile = try await RunnerProfile.query(on: app.db)
            .filter(\.$runnerID == "runner-heartbeat")
            .first()
        XCTAssertEqual(runnerProfile?.platform, "linux")
    }

    func testAdminMetricsAuthorizationAndResponseShape() async throws {
        let (setup, submission) = try await makeSubmission(submissionID: "sub_metrics")
        let recentMetric = JobExecutionMetric(
            submissionID: try submission.requireID(),
            jobID: try submission.requireID(),
            testSetupID: try setup.requireID(),
            courseID: nil,
            assignmentID: nil,
            userID: nil,
            runnerID: "runner-metrics",
            kind: APISubmission.Kind.student,
            attemptNumber: 1,
            enqueuedAt: Date().addingTimeInterval(-10)
        )
        recentMetric.assignedAt = Date().addingTimeInterval(-9)
        recentMetric.startedAt = Date().addingTimeInterval(-8)
        recentMetric.completedAt = Date().addingTimeInterval(-4)
        recentMetric.queueWaitMs = 1000
        recentMetric.executionMs = 4000
        recentMetric.totalProcessingMs = 6000
        recentMetric.finalStatus = JobFinalStatus.passed.rawValue
        recentMetric.testsPassed = 1
        recentMetric.testsFailed = 0
        recentMetric.testsErrored = 0
        recentMetric.testsTimedOut = 0
        recentMetric.skippedCount = 0
        try await recentMetric.save(on: app.db)

        let snapshot = RunnerSnapshot(
            runnerID: "runner-metrics",
            recordedAt: Date().addingTimeInterval(-300),
            activeJobs: 1,
            maxJobs: 3,
            availableCapacity: 2,
            hostname: "host-metrics",
            runnerVersion: "runner/2.0",
            lastPollAt: Date().addingTimeInterval(-300),
            lastHeartbeatAt: Date().addingTimeInterval(-300),
            serverAssignedJobCountSinceStart: 4
        )
        try await snapshot.save(on: app.db)

        let requestMetric = APIRequestMetric(
            method: "GET",
            path: "/api/v1/health",
            requestKind: "api",
            statusCode: 200,
            startedAt: Date().addingTimeInterval(-240),
            finishedAt: Date().addingTimeInterval(-239),
            durationMs: 150,
            submissionID: nil,
            workerID: nil
        )
        try await requestMetric.save(on: app.db)

        await app.workerActivityStore.markActive(
            workerID: "runner-metrics",
            hostname: "host-metrics",
            runnerVersion: "runner/2.0",
            maxConcurrentJobs: 3,
            activeJobs: 1,
            lastHeartbeatAt: Date()
        )

        try await app.asyncTest(
            .GET, "/admin/metrics",
            afterResponse: { response in
                XCTAssertEqual(response.status, .seeOther)
            })

        let cookie = try await loginUser(
            username: "admin-observability",
            password: "password123",
            role: "admin",
            on: app
        )

        try await app.asyncTest(
            .GET, "/admin/metrics",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { response in
                XCTAssertEqual(response.status, .ok)
                let payload = try response.content.decode(InternalMetricsResponse.self)
                XCTAssertGreaterThanOrEqual(payload.activeRunners, 1)
                XCTAssertEqual(payload.jobsProcessed24h, 1)
                XCTAssertNotNil(payload.queueWait.averageMs)
                XCTAssertEqual(payload.jobStatusCounts.first(where: { $0.status == "passed" })?.count, 1)
                XCTAssertFalse(payload.runnerLoads.isEmpty)
                XCTAssertEqual(payload.compatibility.compatibleAssignmentAttempts, 0)
            })

        try await app.asyncTest(
            .GET, "/admin/metrics/timeseries?hours=24&bucketMinutes=15",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { response in
                XCTAssertEqual(response.status, .ok)
                let payload = try response.content.decode(InternalMetricsTimeSeriesResponse.self)
                XCTAssertEqual(payload.windowHours, 24)
                XCTAssertEqual(payload.bucketMinutes, 15)
                XCTAssertFalse(payload.buckets.isEmpty)
                XCTAssertTrue(payload.buckets.contains(where: { $0.completedJobs == 1 }))
                XCTAssertTrue(
                    payload.buckets.contains(where: { ($0.requestCount > 0) || ($0.avgRunnerUtilizationPercent != nil) }
                    ))
            })
    }

    func testQueueDepthExcludesBrowserModePendingJobs() async throws {
        // Only worker-mode submissions should contribute to the native worker queue depth.
        _ = try await makeSubmission(submissionID: "sub_worker_pending", gradingMode: "worker")
        _ = try await makeSubmission(submissionID: "sub_browser_pending", gradingMode: "browser")

        let cookie = try await loginUser(
            username: "admin-queue-depth",
            password: "password123",
            role: "admin",
            on: app
        )

        try await app.asyncTest(
            .GET, "/admin/metrics",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { response in
                XCTAssertEqual(response.status, .ok)
                let payload = try response.content.decode(InternalMetricsResponse.self)
                XCTAssertEqual(payload.maxQueueDepth, 1)
            })
    }

    /// Retests reuse the same `JobExecutionMetric` row. Two things must be
    /// true after the new assignment is recorded:
    /// 1. `enqueuedAt` is re-baselined to `retestedAt`, so `queueWaitMs`
    ///    reflects only the retest window — not the time since the original
    ///    submission was first made.
    /// 2. Per-attempt fields from the previous run (`completedAt`,
    ///    `totalProcessingMs`, `executionMs`, stage timings, etc.) are
    ///    cleared, so an in-flight retest never renders with `Total <
    ///    Queue Wait` on the admin runner page.
    func testRetestClearsStalePerAttemptFieldsAndRebaselinesEnqueue() async throws {
        let (_, submission) = try await makeSubmission(submissionID: "sub_retest")

        // --- Attempt 1: submit, assign, complete. ---
        let originallySubmittedAt = Date(timeIntervalSince1970: 1_000)
        let firstAssignedAt = Date(timeIntervalSince1970: 1_002)
        let firstStartedAt = Date(timeIntervalSince1970: 1_003)
        let firstCompletedAt = Date(timeIntervalSince1970: 1_010)

        submission.submittedAt = originallySubmittedAt
        try await submission.update(on: app.db)
        await app.diagnostics.recordSubmissionCreated(submission: submission, on: app.db, logger: app.logger)

        submission.workerID = "runner-original"
        submission.assignedAt = firstAssignedAt
        submission.status = "assigned"
        try await submission.update(on: app.db)
        await app.diagnostics.recordJobAssigned(submission: submission, on: app.db, logger: app.logger)

        let firstCollection = TestOutcomeCollection(
            submissionID: try submission.requireID(),
            testSetupID: submission.testSetupID,
            attemptNumber: 1,
            buildStatus: .passed,
            compilerOutput: nil,
            outcomes: [],
            totalTests: 0,
            passCount: 0, failCount: 0, errorCount: 0, timeoutCount: 0,
            executionTimeMs: 7_000,
            jobStartedAt: firstStartedAt,
            runnerVersion: "runner-test/1.0",
            timestamp: firstCompletedAt
        )
        await app.diagnostics.recordWorkerResult(
            collection: firstCollection,
            submission: submission,
            on: app.db,
            logger: app.logger
        )

        let postFirstRun = try await JobExecutionMetric.query(on: app.db)
            .filter(\.$submissionID == "sub_retest")
            .first()
        XCTAssertEqual(postFirstRun?.totalProcessingMs, 10_000)  // 1_010 − 1_000
        XCTAssertEqual(postFirstRun?.queueWaitMs, 2_000)  //  1_002 − 1_000
        XCTAssertNotNil(postFirstRun?.completedAt)

        // --- Retest is triggered later, gets re-assigned. ---
        let retestedAt = Date(timeIntervalSince1970: 50_000)
        let retestAssignedAt = Date(timeIntervalSince1970: 50_004)

        submission.retestedAt = retestedAt
        submission.assignedAt = retestAssignedAt
        submission.workerID = "runner-retest"
        submission.status = "assigned"
        try await submission.update(on: app.db)
        await app.diagnostics.recordJobAssigned(submission: submission, on: app.db, logger: app.logger)

        let postRetestAssign = try await JobExecutionMetric.query(on: app.db)
            .filter(\.$submissionID == "sub_retest")
            .first()
        // Queue wait reflects the retest window only (4s), not 49,004s since
        // the original submission.
        XCTAssertEqual(postRetestAssign?.queueWaitMs, 4_000)
        // Per-attempt fields from the previous run are cleared.
        XCTAssertNil(postRetestAssign?.completedAt)
        XCTAssertNil(postRetestAssign?.startedAt)
        XCTAssertNil(postRetestAssign?.executionMs)
        XCTAssertNil(postRetestAssign?.totalProcessingMs)
        XCTAssertNil(postRetestAssign?.finalStatus)
        // Specifically: Total < Queue Wait is no longer possible because
        // totalProcessingMs is nil — the admin page will show "—" until
        // the retest completes.
    }

    private func makeSubmission(
        submissionID: String,
        gradingMode: String = "worker"
    ) async throws -> (APITestSetup, APISubmission) {
        let setup = try await makeSetup(id: "setup_\(submissionID)", gradingMode: gradingMode)
        let submission = APISubmission(
            id: submissionID,
            testSetupID: try setup.requireID(),
            zipPath: "/tmp/\(submissionID).zip",
            attemptNumber: 1,
            status: "pending",
            kind: APISubmission.Kind.student
        )
        try await submission.save(on: app.db)
        return (setup, submission)
    }

    private func makeSetup(
        id: String = "setup_metrics",
        gradingMode: String = "worker"
    ) async throws -> APITestSetup {
        let course = APICourse(code: "OBS_\(id)", name: "Observability", enrollmentMode: .closed)
        try await course.save(on: app.db)
        let setup = APITestSetup(
            id: id,
            manifest:
                #"{"schemaVersion":1,"gradingMode":"\#(gradingMode)","requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}"#,
            zipPath: "/tmp/\(id).zip",
            courseID: try course.requireID()
        )
        try await setup.save(on: app.db)
        return setup
    }

    private func encodedBody<T: Encodable>(_ value: T) throws -> ByteBuffer {
        ByteBuffer(data: try JSONEncoder().encode(value))
    }
}
