import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer
@testable import Core

@Suite(.serialized) final class ObservabilityTests {
    private let workerSecret = "observability-secret"

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-obs")
        app.workerSecretStore = WorkerSecretStore(initialOverride: workerSecret)
    }

    @Test func queueWaitMetricCalculationPersistsExpectedMilliseconds() async throws {
        try await withApp(app) { _ in
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
            #expect(metric?.queueWaitMs == 3500)

        }
    }

    @Test func executionDurationAndFinalStatusPersistence() async throws {
        try await withApp(app) { _ in
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
            #expect(metric?.executionMs == 3250)
            // totalProcessingMs is the sum of queueWaitMs (2000) and executionMs
            // (3250), not `completedAt − enqueuedAt`. Summing avoids mixing
            // server `enqueuedAt` with runner `completedAt`, which under any
            // runner clock skew would let `total < queueWait` slip through.
            #expect(metric?.totalProcessingMs == 5250)
            #expect(metric?.finalStatus == JobFinalStatus.error.rawValue)

        }
    }

    @Test func wrappedExecutionReportPersistsStageTimingMetrics() async throws {
        try await withApp(app) { _ in
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
            #expect(metric?.workdirSetupMs == 10)
            #expect(metric?.submissionDirSetupMs == 15)
            #expect(metric?.submissionDownloadMs == 20)
            #expect(metric?.testSetupAcquireMs == 25)
            #expect(metric?.submissionUnpackMs == 30)
            #expect(metric?.starterCleanupMs == 5)
            #expect(metric?.submissionPrepareMs == 40)
            #expect(metric?.makeStepMs == 50)
            #expect(metric?.runtimeHelperSetupMs == 12)
            #expect(metric?.testExecutionMs == 250)

        }
    }

    @Test func workerHeartbeatUpdatesRunnerSnapshot() async throws {
        try await withApp(app) { _ in
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
                    #expect(response.status == .ok)
                })

            let snapshot = try await RunnerSnapshot.query(on: app.db)
                .filter(\.$runnerID == "runner-heartbeat")
                .sort(\.$recordedAt, .descending)
                .first()
            #expect(snapshot?.activeJobs == 2)
            #expect(snapshot?.maxJobs == 4)
            #expect(snapshot?.availableCapacity == 2)
            #expect(snapshot?.lastHeartbeatAt != nil)

            let runnerProfile = try await RunnerProfile.query(on: app.db)
                .filter(\.$runnerID == "runner-heartbeat")
                .first()
            #expect(runnerProfile?.platform == "linux")

        }
    }

    // swiftlint:disable:next function_body_length
    @Test func adminMetricsAuthorizationAndResponseShape() async throws {
        try await withApp(app) { _ in
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
                    #expect(response.status == .seeOther)
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
                    #expect(response.status == .ok)
                    let payload = try response.content.decode(InternalMetricsResponse.self)
                    XCTAssertGreaterThanOrEqual(payload.activeRunners, 1)
                    #expect(payload.jobsProcessed24h == 1)
                    #expect(payload.queueWait.averageMs != nil)
                    #expect(payload.jobStatusCounts.first(where: { $0.status == "passed" })?.count == 1)
                    #expect(payload.runnerLoads.isEmpty == false)
                    #expect(payload.compatibility.compatibleAssignmentAttempts == 0)
                })

            try await app.asyncTest(
                .GET, "/admin/metrics/timeseries?hours=24&bucketMinutes=15",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { response in
                    #expect(response.status == .ok)
                    let payload = try response.content.decode(InternalMetricsTimeSeriesResponse.self)
                    #expect(payload.windowHours == 24)
                    #expect(payload.bucketMinutes == 15)
                    #expect(payload.buckets.isEmpty == false)
                    #expect(payload.buckets.contains(where: { $0.completedJobs == 1 }))
                    #expect(
                        payload.buckets.contains(where: {
                            ($0.requestCount > 0) || ($0.avgRunnerUtilizationPercent != nil)
                        }
                        ))
                })

        }
    }

    @Test func queueDepthExcludesBrowserModePendingJobs() async throws {
        try await withApp(app) { _ in
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
                    #expect(response.status == .ok)
                    let payload = try response.content.decode(InternalMetricsResponse.self)
                    #expect(payload.maxQueueDepth == 1)
                })

        }
    }

    /// Regression test for the admin runner page showing `Total < Queue
    /// Wait`. Models the production failure mode: the runner's wall clock
    /// is offset relative to the server, so the runner-reported
    /// `finishedAt` lands "before" the server-recorded `assignedAt` in
    /// absolute time. The old formula
    /// (`completedAt − enqueuedAt`) straddled the two clocks and produced
    /// totals smaller than the queue wait. `totalProcessingMs` must now
    /// be `queueWaitMs + executionMs`, which never inverts.
    @Test func totalProcessingMsIsResilientToRunnerClockSkew() async throws {
        try await withApp(app) { _ in
            let (_, submission) = try await makeSubmission(submissionID: "sub_clock_skew")

            // Server clock: submitted at T+0, assigned 210 ms later.
            let enqueuedAt = Date(timeIntervalSince1970: 10_000.000)
            let assignedAt = Date(timeIntervalSince1970: 10_000.210)

            submission.submittedAt = enqueuedAt
            submission.workerID = "runner-skewed"
            submission.assignedAt = assignedAt
            submission.status = "assigned"
            try await submission.update(on: app.db)

            await app.diagnostics.recordSubmissionCreated(submission: submission, on: app.db, logger: app.logger)
            await app.diagnostics.recordJobAssigned(submission: submission, on: app.db, logger: app.logger)

            // Runner clock runs ~200ms behind the server, so its reported
            // start/finish timestamps land "before" assignedAt in absolute
            // time. wallClockMs (a duration on the runner's clock) is correct.
            let runnerStartedAt = Date(timeIntervalSince1970: 10_000.010)
            let runnerFinishedAt = Date(timeIntervalSince1970: 10_000.111)

            let collection = TestOutcomeCollection(
                submissionID: try submission.requireID(),
                testSetupID: submission.testSetupID,
                attemptNumber: submission.attemptNumber ?? 1,
                buildStatus: .passed,
                compilerOutput: nil,
                outcomes: [],
                totalTests: 0,
                passCount: 0, failCount: 0, errorCount: 0, timeoutCount: 0,
                executionTimeMs: 101,
                jobStartedAt: runnerStartedAt,
                runnerVersion: "runner-test/1.0",
                timestamp: runnerFinishedAt
            )
            await app.diagnostics.recordWorkerResult(
                collection: collection,
                submission: submission,
                on: app.db,
                logger: app.logger
            )

            let metric = try await JobExecutionMetric.query(on: app.db)
                .filter(\.$submissionID == "sub_clock_skew")
                .first()
            #expect(metric?.queueWaitMs == 210)
            #expect(metric?.executionMs == 101)
            // The invariant: total >= queueWait. The old formula yielded 111ms
            // (a clock-skewed completedAt − enqueuedAt), inverting against
            // the 210ms queueWait. The summed formula yields 311ms.
            #expect(metric?.totalProcessingMs == 311)
            if let total = metric?.totalProcessingMs, let queue = metric?.queueWaitMs {
                XCTAssertGreaterThanOrEqual(total, queue)
            } else {
                XCTFail("expected queueWaitMs and totalProcessingMs to be populated")
            }

            // Same invariant on APISubmissionDiagnostics.turnaroundMs.
            let diag = try await APISubmissionDiagnostics.find("sub_clock_skew", on: app.db)
            #expect(diag?.turnaroundMs == 311)
            if let turnaround = diag?.turnaroundMs, let queue = diag?.queueWaitMs {
                XCTAssertGreaterThanOrEqual(turnaround, queue)
            }

        }
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
    @Test func retestClearsStalePerAttemptFieldsAndRebaselinesEnqueue() async throws {
        try await withApp(app) { _ in
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
            #expect(postFirstRun?.totalProcessingMs == 9_000)  // queueWait 2_000 + execution 7_000
            #expect(postFirstRun?.queueWaitMs == 2_000)  //  1_002 − 1_000
            #expect(postFirstRun?.completedAt != nil)

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
            #expect(postRetestAssign?.queueWaitMs == 4_000)
            // Per-attempt fields from the previous run are cleared.
            #expect(postRetestAssign?.completedAt == nil)
            #expect(postRetestAssign?.startedAt == nil)
            #expect(postRetestAssign?.executionMs == nil)
            #expect(postRetestAssign?.totalProcessingMs == nil)
            #expect(postRetestAssign?.finalStatus == nil)
            // Specifically: Total < Queue Wait is no longer possible because
            // totalProcessingMs is nil — the admin page will show "—" until
            // the retest completes.

        }
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
