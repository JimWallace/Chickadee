import XCTest
import XCTVapor
@testable import chickadee_server
import Fluent
@testable import Core
import Foundation

final class ObservabilityTests: XCTestCase {
    private var app: Application!
    private let workerSecret = "observability-secret"

    override func setUp() async throws {
        app = try await Application.make(.testing)
        app.sessions.use(.memory)
        app.middleware.use(app.sessions.middleware)
        app.workerSecretStore = WorkerSecretStore(initialOverride: workerSecret)

        try await configureTestDatabase(app, options: .runnerCompatibility)

        configureLeaf(app)
        try routes(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
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

        try await app.asyncTest(.POST, path, beforeRequest: { req in
            req.headers = workerHMACHeaders(
                method: .POST,
                path: path,
                body: body,
                workerSecret: self.workerSecret,
                workerID: payload.workerID
            )
            req.body = body
        }, afterResponse: { response in
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

        try await app.asyncTest(.GET, "/admin/metrics", afterResponse: { response in
            XCTAssertEqual(response.status, .seeOther)
        })

        let cookie = try await loginUser(
            username: "admin-observability",
            password: "password123",
            role: "admin",
            on: app
        )

        try await app.asyncTest(.GET, "/admin/metrics", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(InternalMetricsResponse.self)
            XCTAssertGreaterThanOrEqual(payload.activeRunners, 1)
            XCTAssertNotNil(payload.queueWait.averageMs)
            XCTAssertEqual(payload.jobStatusCounts.first(where: { $0.status == "passed" })?.count, 1)
            XCTAssertFalse(payload.runnerLoads.isEmpty)
            XCTAssertEqual(payload.compatibility.compatibleAssignmentAttempts, 0)
        })

        try await app.asyncTest(.GET, "/admin/metrics/timeseries?hours=24&bucketMinutes=15", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { response in
            XCTAssertEqual(response.status, .ok)
            let payload = try response.content.decode(InternalMetricsTimeSeriesResponse.self)
            XCTAssertEqual(payload.windowHours, 24)
            XCTAssertEqual(payload.bucketMinutes, 15)
            XCTAssertFalse(payload.buckets.isEmpty)
            XCTAssertTrue(payload.buckets.contains(where: { $0.completedJobs == 1 }))
            XCTAssertTrue(payload.buckets.contains(where: { ($0.requestCount > 0) || ($0.avgRunnerUtilizationPercent != nil) }))
        })
    }

    private func makeSubmission(submissionID: String) async throws -> (APITestSetup, APISubmission) {
        let setup = try await makeSetup(id: "setup_\(submissionID)")
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

    private func makeSetup(id: String = "setup_metrics") async throws -> APITestSetup {
        let course = APICourse(code: "OBS_\(id)", name: "Observability", enrollmentMode: .closed)
        try await course.save(on: app.db)
        let setup = APITestSetup(
            id: id,
            manifest: #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}"#,
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
