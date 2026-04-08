import Core
import Fluent
import Vapor
import Foundation

enum JobFinalStatus: String, CaseIterable, Codable, Sendable {
    case passed
    case failed
    case error
    case timeout
}

enum RunnerCheckInReason: String, Sendable {
    case poll
    case heartbeat
    case auth
}

enum ObservabilityEvent: String, Sendable {
    case submissionAccepted = "submission_accepted"
    case jobEnqueued = "job_enqueued"
    case runnerPolled = "runner_polled"
    case runnerHeartbeat = "runner_heartbeat"
    case runnerProfileRegistered = "runner_profile_registered"
    case runnerProfileUpdated = "runner_profile_updated"
    case assignmentRequirementsLoaded = "assignment_requirements_loaded"
    case compatibilityCheckPassed = "compatibility_check_passed"
    case compatibilityCheckFailed = "compatibility_check_failed"
    case noCompatibleRunnerAvailable = "no_compatible_runner_available"
    case jobAssignedToCompatibleRunner = "job_assigned_to_compatible_runner"
    case jobAssigned = "job_assigned"
    case resultReceived = "result_received"
    case jobFinalised = "job_finalised"
    case assignmentResultSummary = "assignment_result_summary"
    case testResultSummary = "test_result_summary"
    case jobRecovery = "job_recovery"
}

struct RunnerAverages: Sendable {
    let avgExecutionMs: Int?
    let avgQueueWaitMs: Int?
}

struct DiagnosticsConfiguration: Sendable {
    let enabled: Bool
    let verboseRequestTiming: Bool
    let jobMetricRetentionDays: Int
    let runnerSnapshotRetentionDays: Int
    let activeRunnerWindowSeconds: TimeInterval
    let recentMetricsWindowHours: Int
    let pruneIntervalHours: Int

    static func fromEnvironment() -> Self {
        Self(
            enabled: environmentBool("ENABLE_DIAGNOSTICS_COLLECTION") ?? true,
            verboseRequestTiming: environmentBool("VERBOSE_REQUEST_TIMING") ?? false,
            jobMetricRetentionDays: environmentInt("JOB_METRIC_RETENTION_DAYS") ?? 30,
            runnerSnapshotRetentionDays: environmentInt("RUNNER_SNAPSHOT_RETENTION_DAYS") ?? 14,
            activeRunnerWindowSeconds: TimeInterval(environmentInt("RUNNER_ACTIVE_WINDOW_SECONDS") ?? 120),
            recentMetricsWindowHours: environmentInt("METRICS_RECENT_WINDOW_HOURS") ?? 24,
            pruneIntervalHours: environmentInt("OBSERVABILITY_PRUNE_INTERVAL_HOURS") ?? 24
        )
    }
}

struct InternalMetricsResponse: Content, Sendable {
    let generatedAt: Date
    let maxQueueDepth: Int
    let jobsProcessed24h: Int
    let peakUtilizationPercent: Int?
    let maxLoadActiveJobs: Int?
    let maxLoadCapacity: Int?
    let activeRunners: Int
    let runnerLoads: [RunnerLoadResponse]
    let recentWindowHours: Int
    let jobStatusCounts: [StatusCountResponse]
    let queueWait: DurationSummaryResponse
    let execution: DurationSummaryResponse
    let compatibility: CompatibilityCountersResponse
}

struct InternalMetricsTimeSeriesResponse: Content, Sendable {
    let generatedAt: Date
    let windowHours: Int
    let bucketMinutes: Int
    let buckets: [InternalMetricsBucketResponse]
}

struct InternalMetricsBucketResponse: Content, Sendable {
    let bucketStart: Date
    let avgRunnerUtilizationPercent: Int?
    let maxRunnerUtilizationPercent: Int?
    let avgActiveRunners: Int
    let requestCount: Int
    let requestP95Ms: Int?
    let completedJobs: Int
    let passedCount: Int
    let failedCount: Int
    let errorCount: Int
    let timeoutCount: Int
    let queueWaitP95Ms: Int?
    let executionP95Ms: Int?
}

struct RunnerLoadResponse: Content, Sendable {
    let runnerID: String
    let hostname: String
    let activeJobs: Int
    let maxJobs: Int
    let availableCapacity: Int
    let lastSeenAt: Date
    let lastPollAt: Date?
    let lastHeartbeatAt: Date?
    let assignedJobsSinceStart: Int
}

struct StatusCountResponse: Content, Sendable {
    let status: String
    let count: Int
}

struct DurationSummaryResponse: Content, Sendable {
    let averageMs: Int?
    let p50Ms: Int?
    let p95Ms: Int?
}

struct CompatibilityCountersResponse: Content, Sendable {
    let compatibleAssignmentAttempts: Int
    let incompatibleAssignmentAttempts: Int
    let jobsBlockedNoCompatibleRunner: Int
}

private struct RunnerBucketAccumulator {
    var sampleCount = 0
    var activeRunnerTotal = 0
    var utilizationValues: [Int] = []
}

private struct RequestBucketAccumulator {
    var requestCount = 0
    var durationValues: [Int] = []
}

private struct JobBucketAccumulator {
    var completedJobs = 0
    var passedCount = 0
    var failedCount = 0
    var errorCount = 0
    var timeoutCount = 0
    var queueWaitValues: [Int] = []
    var executionValues: [Int] = []
}

actor DiagnosticsMaintenanceStore {
    private var lastPrunedAt: Date?

    func shouldPrune(now: Date, intervalHours: Int) -> Bool {
        guard intervalHours > 0 else { return false }
        guard let lastPrunedAt else { return true }
        return now.timeIntervalSince(lastPrunedAt) >= Double(intervalHours) * 3600
    }

    func markPruned(at date: Date) {
        lastPrunedAt = date
    }
}

actor CompatibilityCounterStore {
    private var compatibleAssignmentAttempts = 0
    private var incompatibleAssignmentAttempts = 0
    private var jobsBlockedNoCompatibleRunner = 0

    func incrementCompatibleAssignmentAttempts() {
        compatibleAssignmentAttempts += 1
    }

    func incrementIncompatibleAssignmentAttempts() {
        incompatibleAssignmentAttempts += 1
    }

    func incrementJobsBlockedNoCompatibleRunner() {
        jobsBlockedNoCompatibleRunner += 1
    }

    func snapshot() -> CompatibilityCountersResponse {
        CompatibilityCountersResponse(
            compatibleAssignmentAttempts: compatibleAssignmentAttempts,
            incompatibleAssignmentAttempts: incompatibleAssignmentAttempts,
            jobsBlockedNoCompatibleRunner: jobsBlockedNoCompatibleRunner
        )
    }
}

final class OperationalDiagnosticsService: @unchecked Sendable {
    let configuration: DiagnosticsConfiguration
    private let maintenance = DiagnosticsMaintenanceStore()
    private let compatibilityCounters = CompatibilityCounterStore()

    init(configuration: DiagnosticsConfiguration) {
        self.configuration = configuration
    }

    func recordSubmissionCreated(
        submission: APISubmission,
        on db: Database,
        logger: Logger
    ) async {
        guard configuration.enabled, let submissionID = submission.id else { return }
        do {
            let context = try await loadSubmissionContext(for: submission, on: db)
            let diagnostics = try await findOrCreateSubmissionDiagnostics(
                submission: submission,
                context: context,
                on: db
            )
            diagnostics.submittedAt = submission.submittedAt ?? diagnostics.submittedAt
            try await diagnostics.save(on: db)

            let metric = try await findOrCreateJobExecutionMetric(
                submission: submission,
                context: context,
                on: db
            )
            metric.enqueuedAt = submission.submittedAt ?? metric.enqueuedAt
            try await metric.save(on: db)

            let queueDepth = try await pendingQueueDepth(on: db)
            logger.info(
                "observability",
                metadata: logMetadata(
                    event: .submissionAccepted,
                    submission: submission,
                    context: context,
                    extra: ["status": .string("accepted")]
                )
            )
            logger.info(
                "observability",
                metadata: logMetadata(
                    event: .jobEnqueued,
                    submission: submission,
                    context: context,
                    extra: [
                        "status": .string("pending"),
                        "queue_depth": .stringConvertible(queueDepth),
                    ]
                )
            )
            try await pruneIfNeeded(on: db, logger: logger)
        } catch {
            logger.warning("diagnostics_submission_create_failed", metadata: [
                "submission_id": .string(submissionID),
                "error": .string(String(describing: error)),
            ])
        }
    }

    func recordRunnerCheckIn(
        snapshot: WorkerActivitySnapshot,
        reason: RunnerCheckInReason,
        on db: Database,
        logger: Logger
    ) async {
        guard configuration.enabled else { return }
        do {
            let row = RunnerSnapshot(
                runnerID: snapshot.workerID,
                recordedAt: snapshot.lastActive,
                activeJobs: snapshot.activeJobs,
                maxJobs: snapshot.maxConcurrentJobs,
                availableCapacity: max(0, snapshot.maxConcurrentJobs - snapshot.activeJobs),
                hostname: snapshot.hostname.isEmpty ? nil : snapshot.hostname,
                runnerVersion: snapshot.runnerVersion.isEmpty ? nil : snapshot.runnerVersion,
                lastPollAt: snapshot.lastPollAt,
                lastHeartbeatAt: snapshot.lastHeartbeatAt,
                serverAssignedJobCountSinceStart: snapshot.serverAssignedJobCountSinceStart
            )
            try await row.save(on: db)

            let event: ObservabilityEvent = reason == .poll ? .runnerPolled : .runnerHeartbeat
            logger.info(
                "observability",
                metadata: runnerMetadata(
                    event: event,
                    snapshot: snapshot,
                    extra: [
                        "status": .string("ok"),
                        "available_capacity": .stringConvertible(max(0, snapshot.maxConcurrentJobs - snapshot.activeJobs)),
                    ]
                )
            )
            try await pruneIfNeeded(on: db, logger: logger)
        } catch {
            logger.warning("diagnostics_runner_snapshot_failed", metadata: [
                "runner_id": .string(snapshot.workerID),
                "reason": .string(reason.rawValue),
                "error": .string(String(describing: error)),
            ])
        }
    }

    func recordRunnerProfileEvent(
        profile: RunnerProfile,
        event: RunnerProfileRegistrationEvent,
        logger: Logger
    ) {
        let capabilityProfile = profile.capabilityProfile
        logger.info(
            "observability",
            metadata: [
                "timestamp": iso8601Metadata(Date()),
                "event": .string(
                    event == .registered
                        ? ObservabilityEvent.runnerProfileRegistered.rawValue
                        : ObservabilityEvent.runnerProfileUpdated.rawValue
                ),
                "runner_id": .string(profile.runnerID),
                "platform": .string(capabilityProfile.platform),
                "architecture": .string(capabilityProfile.architecture),
                "languages": .string(capabilityProfile.languageVersions.map {
                    "\($0.language)=\($0.version)"
                }.joined(separator: ",")),
                "capabilities_count": .stringConvertible(capabilityProfile.capabilities.count),
                "status": .string(event.rawValue),
            ]
        )
    }

    func recordAssignmentRequirementsLoaded(
        submission: APISubmission,
        assignmentID: UUID?,
        requirements: AssignmentRequirementSpec?,
        logger: Logger
    ) {
        logger.info(
            "observability",
            metadata: compatibilityMetadata(
                event: .assignmentRequirementsLoaded,
                submission: submission,
                assignmentID: assignmentID,
                runnerID: submission.workerID,
                requirements: requirements,
                extra: [
                    "status": .string("loaded"),
                ]
            )
        )
    }

    func recordCompatibilityDecision(
        submission: APISubmission,
        assignmentID: UUID?,
        runnerID: String,
        requirements: AssignmentRequirementSpec?,
        result: CompatibilityResult,
        logger: Logger
    ) async {
        if result.isCompatible {
            await compatibilityCounters.incrementCompatibleAssignmentAttempts()
        } else {
            await compatibilityCounters.incrementIncompatibleAssignmentAttempts()
        }

        logger.info(
            "observability",
            metadata: compatibilityMetadata(
                event: result.isCompatible ? .compatibilityCheckPassed : .compatibilityCheckFailed,
                submission: submission,
                assignmentID: assignmentID,
                runnerID: runnerID,
                requirements: requirements,
                extra: [
                    "status": .string(result.isCompatible ? "compatible" : "incompatible"),
                    "compatibility_reasons": .string(result.reasons.joined(separator: "; ")),
                ]
            )
        )
    }

    func recordNoCompatibleRunnerAvailable(
        submission: APISubmission,
        assignmentID: UUID?,
        runnerID: String,
        requirements: AssignmentRequirementSpec?,
        result: CompatibilityResult,
        logger: Logger
    ) async {
        await compatibilityCounters.incrementJobsBlockedNoCompatibleRunner()
        logger.warning(
            "observability",
            metadata: compatibilityMetadata(
                event: .noCompatibleRunnerAvailable,
                submission: submission,
                assignmentID: assignmentID,
                runnerID: runnerID,
                requirements: requirements,
                extra: [
                    "status": .string("blocked"),
                    "compatibility_reasons": .string(result.reasons.joined(separator: "; ")),
                ]
            )
        )
    }

    func recordCompatibleJobAssignment(
        submission: APISubmission,
        assignmentID: UUID?,
        runnerID: String,
        requirements: AssignmentRequirementSpec?,
        logger: Logger
    ) {
        logger.info(
            "observability",
            metadata: compatibilityMetadata(
                event: .jobAssignedToCompatibleRunner,
                submission: submission,
                assignmentID: assignmentID,
                runnerID: runnerID,
                requirements: requirements,
                extra: [
                    "status": .string("assigned"),
                ]
            )
        )
    }

    func recordJobAssigned(
        submission: APISubmission,
        on db: Database,
        logger: Logger
    ) async {
        guard configuration.enabled, let submissionID = submission.id else { return }
        do {
            let context = try await loadSubmissionContext(for: submission, on: db)
            let diagnostics = try await findOrCreateSubmissionDiagnostics(
                submission: submission,
                context: context,
                on: db
            )
            diagnostics.assignedAt = submission.assignedAt ?? diagnostics.assignedAt
            diagnostics.runnerID = submission.workerID ?? diagnostics.runnerID
            try await diagnostics.save(on: db)

            let metric = try await findOrCreateJobExecutionMetric(
                submission: submission,
                context: context,
                on: db
            )
            metric.assignedAt = submission.assignedAt ?? metric.assignedAt
            metric.runnerID = submission.workerID ?? metric.runnerID
            metric.queueWaitMs = millisecondsBetween(metric.enqueuedAt, metric.assignedAt)
            try await metric.save(on: db)

            let queueDepth = try await pendingQueueDepth(on: db)
            logger.info(
                "observability",
                metadata: logMetadata(
                    event: .jobAssigned,
                    submission: submission,
                    context: context,
                    extra: [
                        "status": .string("assigned"),
                        "queue_wait_ms": metric.queueWaitMs.map { .stringConvertible($0) } ?? .string(""),
                        "queue_depth": .stringConvertible(queueDepth),
                    ]
                )
            )
        } catch {
            logger.warning("diagnostics_job_assign_failed", metadata: [
                "submission_id": .string(submissionID),
                "error": .string(String(describing: error)),
            ])
        }
    }

    func recordWorkerExecutionReport(
        collection: TestOutcomeCollection,
        diagnostics workerDiagnostics: WorkerExecutionDiagnostics?,
        on db: Database,
        logger: Logger
    ) async {
        guard configuration.enabled else { return }
        do {
            guard let submission = try await APISubmission.find(collection.submissionID, on: db) else {
                logger.warning("diagnostics_missing_submission", metadata: [
                    "submission_id": .string(collection.submissionID),
                ])
                return
            }
            let context = try await loadSubmissionContext(for: submission, on: db)
            let diagnostics = try await findOrCreateSubmissionDiagnostics(
                submission: submission,
                context: context,
                on: db
            )

            let completedAt = workerDiagnostics?.finishedAt ?? collection.timestamp
            let startedAt = workerDiagnostics?.startedAt ?? collection.jobStartedAt ?? diagnostics.startedAt ?? submission.assignedAt
            let finalStatus = workerDiagnostics?.finalStatus ?? inferredFinalStatus(from: collection).rawValue

            diagnostics.submittedAt = submission.submittedAt ?? diagnostics.submittedAt
            diagnostics.assignedAt = submission.assignedAt ?? diagnostics.assignedAt
            diagnostics.runnerID = workerDiagnostics?.runnerID ?? submission.workerID ?? diagnostics.runnerID
            diagnostics.startedAt = startedAt
            diagnostics.finishedAt = completedAt
            // For re-tested submissions use the re-test timestamp as the effective enqueue
            // time so wait and turnaround stats reflect only the re-test queue cycle.
            let effectiveEnqueuedAt = submission.retestedAt ?? diagnostics.submittedAt
            diagnostics.queueWaitMs = millisecondsBetween(effectiveEnqueuedAt, diagnostics.assignedAt)
            diagnostics.executionMs = workerDiagnostics?.wallClockMs
                ?? millisecondsBetween(startedAt, completedAt)
            diagnostics.turnaroundMs = millisecondsBetween(effectiveEnqueuedAt, completedAt)
            diagnostics.finalStatus = finalStatus
            diagnostics.timedOut = finalStatus == JobFinalStatus.timeout.rawValue
            diagnostics.exitCode = workerDiagnostics?.exitCode
            diagnostics.terminationReason = workerDiagnostics?.terminationReason
                ?? inferredTerminationReason(from: collection)
            diagnostics.peakRSSBytes = workerDiagnostics?.peakRSSBytes
            diagnostics.wallClockMs = workerDiagnostics?.wallClockMs
            diagnostics.childProcessCount = workerDiagnostics?.childProcessCount
            diagnostics.stdoutBytes = workerDiagnostics?.stdoutBytes
            diagnostics.stderrBytes = workerDiagnostics?.stderrBytes
            try await diagnostics.save(on: db)

            let metric = try await findOrCreateJobExecutionMetric(
                submission: submission,
                context: context,
                on: db
            )
            metric.runnerID = diagnostics.runnerID
            metric.assignedAt = submission.assignedAt ?? metric.assignedAt
            metric.startedAt = startedAt
            metric.completedAt = completedAt
            metric.queueWaitMs = millisecondsBetween(metric.enqueuedAt, metric.assignedAt)
            metric.executionMs = workerDiagnostics?.wallClockMs ?? millisecondsBetween(startedAt, completedAt)
            metric.totalProcessingMs = millisecondsBetween(metric.enqueuedAt, completedAt)
            metric.workdirSetupMs = workerDiagnostics?.stageTimings?.workdirSetupMs
            metric.submissionDirSetupMs = workerDiagnostics?.stageTimings?.submissionDirSetupMs
            metric.submissionDownloadMs = workerDiagnostics?.stageTimings?.submissionDownloadMs
            metric.testSetupAcquireMs = workerDiagnostics?.stageTimings?.testSetupAcquireMs
            metric.submissionUnpackMs = workerDiagnostics?.stageTimings?.submissionUnpackMs
            metric.starterCleanupMs = workerDiagnostics?.stageTimings?.starterCleanupMs
            metric.submissionPrepareMs = workerDiagnostics?.stageTimings?.submissionPrepareMs
            metric.makeStepMs = workerDiagnostics?.stageTimings?.makeStepMs
            metric.runtimeHelperSetupMs = workerDiagnostics?.stageTimings?.runtimeHelperSetupMs
            metric.testExecutionMs = workerDiagnostics?.stageTimings?.testExecutionMs
            metric.finalStatus = finalStatus
            metric.testsPassed = collection.passCount
            metric.testsFailed = collection.failCount
            metric.testsErrored = collection.errorCount
            metric.testsTimedOut = collection.timeoutCount
            metric.skippedCount = skippedCount(in: collection.outcomes)
            try await metric.save(on: db)

            logger.info(
                "observability",
                metadata: logMetadata(
                    event: .resultReceived,
                    submission: submission,
                    context: context,
                    extra: [
                        "status": .string("received"),
                        "tests_passed": .stringConvertible(collection.passCount),
                        "tests_failed": .stringConvertible(collection.failCount),
                        "tests_errored": .stringConvertible(collection.errorCount),
                        "tests_timed_out": .stringConvertible(collection.timeoutCount),
                        "skipped_count": .stringConvertible(metric.skippedCount ?? 0),
                    ]
                )
            )
            logger.info(
                "observability",
                metadata: logMetadata(
                    event: .assignmentResultSummary,
                    submission: submission,
                    context: context,
                    extra: [
                        "final_status": .string(finalStatus),
                        "queue_wait_ms": metric.queueWaitMs.map { .stringConvertible($0) } ?? .string(""),
                        "execution_ms": metric.executionMs.map { .stringConvertible($0) } ?? .string(""),
                        "total_processing_ms": metric.totalProcessingMs.map { .stringConvertible($0) } ?? .string(""),
                        "tests_passed": .stringConvertible(collection.passCount),
                        "tests_failed": .stringConvertible(collection.failCount),
                        "tests_errored": .stringConvertible(collection.errorCount),
                        "tests_timed_out": .stringConvertible(collection.timeoutCount),
                        "skipped_count": .stringConvertible(metric.skippedCount ?? 0),
                    ]
                )
            )

            for outcome in collection.outcomes {
                logger.info(
                    "observability",
                    metadata: logMetadata(
                        event: .testResultSummary,
                        submission: submission,
                        context: context,
                        extra: [
                            "test_id": .string(normalizedTestID(for: outcome)),
                            "status": .string(outcome.status.rawValue),
                            "execution_ms": .stringConvertible(outcome.executionTimeMs),
                            "error_message_summary": .string(compactSummary(outcome.shortResult)),
                        ]
                    )
                )
            }

            logger.info(
                "observability",
                metadata: logMetadata(
                    event: .jobFinalised,
                    submission: submission,
                    context: context,
                    extra: [
                        "final_status": .string(finalStatus),
                        "queue_wait_ms": metric.queueWaitMs.map { .stringConvertible($0) } ?? .string(""),
                        "execution_ms": metric.executionMs.map { .stringConvertible($0) } ?? .string(""),
                        "total_processing_ms": metric.totalProcessingMs.map { .stringConvertible($0) } ?? .string(""),
                    ]
                )
            )
            try await pruneIfNeeded(on: db, logger: logger)
        } catch {
            logger.warning("diagnostics_job_finish_failed", metadata: [
                "submission_id": .string(collection.submissionID),
                "error": .string(String(describing: error)),
            ])
        }
    }

    func recordWorkerResult(
        collection: TestOutcomeCollection,
        submission: APISubmission,
        on db: Database,
        logger: Logger
    ) async {
        let finishedAt = collection.timestamp
        let workerDiag = WorkerExecutionDiagnostics(
            runnerID: submission.workerID ?? "",
            startedAt: collection.jobStartedAt ?? submission.assignedAt,
            finishedAt: finishedAt,
            finalStatus: inferredFinalStatus(from: collection).rawValue,
            timedOut: collection.timeoutCount > 0,
            exitCode: nil,
            terminationReason: inferredTerminationReason(from: collection),
            peakRSSBytes: nil,
            wallClockMs: collection.executionTimeMs,
            childProcessCount: nil,
            stdoutBytes: nil,
            stderrBytes: nil
        )
        await recordWorkerExecutionReport(
            collection: collection,
            diagnostics: workerDiag,
            on: db,
            logger: logger
        )
    }

    func recordJobFailure(
        submissionID: String,
        runnerID: String?,
        startedAt: Date?,
        finishedAt: Date?,
        terminationReason: String,
        on db: Database,
        logger: Logger
    ) async {
        guard configuration.enabled else { return }
        do {
            guard let submission = try await APISubmission.find(submissionID, on: db) else { return }
            let context = try await loadSubmissionContext(for: submission, on: db)
            let diagnostics = try await findOrCreateSubmissionDiagnostics(
                submission: submission,
                context: context,
                on: db
            )
            diagnostics.runnerID = runnerID ?? diagnostics.runnerID
            diagnostics.startedAt = startedAt ?? diagnostics.startedAt
            diagnostics.finishedAt = finishedAt ?? diagnostics.finishedAt
            diagnostics.queueWaitMs = millisecondsBetween(diagnostics.submittedAt, submission.assignedAt)
            diagnostics.executionMs = millisecondsBetween(diagnostics.startedAt, diagnostics.finishedAt)
            diagnostics.turnaroundMs = millisecondsBetween(diagnostics.submittedAt, diagnostics.finishedAt)
            diagnostics.finalStatus = terminationReason == "job_timeout"
                ? JobFinalStatus.timeout.rawValue
                : JobFinalStatus.error.rawValue
            diagnostics.timedOut = terminationReason == "job_timeout"
            diagnostics.terminationReason = terminationReason
            try await diagnostics.save(on: db)

            let metric = try await findOrCreateJobExecutionMetric(
                submission: submission,
                context: context,
                on: db
            )
            metric.runnerID = runnerID ?? metric.runnerID
            metric.startedAt = startedAt ?? metric.startedAt
            metric.completedAt = finishedAt ?? metric.completedAt
            metric.queueWaitMs = millisecondsBetween(metric.enqueuedAt, submission.assignedAt)
            metric.executionMs = millisecondsBetween(metric.startedAt, metric.completedAt)
            metric.totalProcessingMs = millisecondsBetween(metric.enqueuedAt, metric.completedAt)
            metric.finalStatus = terminationReason == "job_timeout"
                ? JobFinalStatus.timeout.rawValue
                : JobFinalStatus.error.rawValue
            try await metric.save(on: db)

            logger.error(
                "observability",
                metadata: logMetadata(
                    event: .jobRecovery,
                    submission: submission,
                    context: context,
                    extra: [
                        "final_status": .string(metric.finalStatus ?? JobFinalStatus.error.rawValue),
                        "error_type": .string(terminationReason),
                        "queue_wait_ms": metric.queueWaitMs.map { .stringConvertible($0) } ?? .string(""),
                        "execution_ms": metric.executionMs.map { .stringConvertible($0) } ?? .string(""),
                    ]
                )
            )
        } catch {
            logger.warning("diagnostics_job_failure_record_failed", metadata: [
                "submission_id": .string(submissionID),
                "error": .string(String(describing: error)),
            ])
        }
    }

    func rollingAverages(
        for runnerIDs: [String],
        sampleSize: Int = 50,
        on db: Database
    ) async throws -> [String: RunnerAverages] {
        guard !runnerIDs.isEmpty else { return [:] }
        let metrics = try await JobExecutionMetric.query(on: db)
            .filter(\.$runnerID ~~ runnerIDs)
            .sort(\.$completedAt, .descending)
            .limit(runnerIDs.count * sampleSize)
            .all()

        var execByRunner: [String: [Int]] = [:]
        var waitByRunner: [String: [Int]] = [:]
        for metric in metrics {
            guard let runnerID = metric.runnerID else { continue }
            if let executionMs = metric.executionMs, execByRunner[runnerID, default: []].count < sampleSize {
                execByRunner[runnerID, default: []].append(executionMs)
            }
            if let queueWaitMs = metric.queueWaitMs, waitByRunner[runnerID, default: []].count < sampleSize {
                waitByRunner[runnerID, default: []].append(queueWaitMs)
            }
        }

        var result: [String: RunnerAverages] = [:]
        for runnerID in runnerIDs {
            let exec = execByRunner[runnerID] ?? []
            let wait = waitByRunner[runnerID] ?? []
            result[runnerID] = RunnerAverages(
                avgExecutionMs: exec.isEmpty ? nil : exec.reduce(0, +) / exec.count,
                avgQueueWaitMs: wait.isEmpty ? nil : wait.reduce(0, +) / wait.count
            )
        }
        return result
    }

    func metricsSnapshot(req: Request) async throws -> InternalMetricsResponse {
        try await req.application.runnerProfiles.refreshActiveFlags(
            activeWindowSeconds: configuration.activeRunnerWindowSeconds,
            on: req.db
        )
        let now = Date()
        let windowHours = max(1, configuration.recentMetricsWindowHours)
        let windowStart = now.addingTimeInterval(Double(-windowHours) * 3600)

        let runnerSnapshots = try await RunnerSnapshot.query(on: req.db)
            .filter(\.$recordedAt >= windowStart)
            .sort(\.$recordedAt, .ascending)
            .all()
        let activeSnapshots = await req.application.workerActivityStore.snapshotsSortedByRecent()
            .filter { now.timeIntervalSince($0.lastActive) <= configuration.activeRunnerWindowSeconds }
        let recentMetrics = try await JobExecutionMetric.query(on: req.db)
            .filter(\.$completedAt >= windowStart)
            .all()
        let maxQueueDepth = try await maxQueueDepthSince(windowStart: windowStart, now: now, on: req.db)
        let peakLoadSnapshot = peakLoad(from: runnerSnapshots)

        var statusCounts: [String: Int] = [:]
        var queueWaitValues: [Int] = []
        var executionValues: [Int] = []
        for metric in recentMetrics {
            if let finalStatus = metric.finalStatus {
                statusCounts[finalStatus, default: 0] += 1
            }
            if let queueWaitMs = metric.queueWaitMs {
                queueWaitValues.append(queueWaitMs)
            }
            if let executionMs = metric.executionMs {
                executionValues.append(executionMs)
            }
        }

        let runnerLoads = activeSnapshots.map {
            RunnerLoadResponse(
                runnerID: $0.workerID,
                hostname: $0.hostname,
                activeJobs: $0.activeJobs,
                maxJobs: $0.maxConcurrentJobs,
                availableCapacity: max(0, $0.maxConcurrentJobs - $0.activeJobs),
                lastSeenAt: $0.lastActive,
                lastPollAt: $0.lastPollAt,
                lastHeartbeatAt: $0.lastHeartbeatAt,
                assignedJobsSinceStart: $0.serverAssignedJobCountSinceStart
            )
        }

        let compatibilitySnapshot = await compatibilityCounters.snapshot()

        return InternalMetricsResponse(
            generatedAt: now,
            maxQueueDepth: maxQueueDepth,
            jobsProcessed24h: recentMetrics.count,
            peakUtilizationPercent: peakUtilizationPercent(from: runnerSnapshots),
            maxLoadActiveJobs: peakLoadSnapshot?.activeJobs,
            maxLoadCapacity: peakLoadSnapshot?.maxJobs,
            activeRunners: activeSnapshots.count,
            runnerLoads: runnerLoads,
            recentWindowHours: windowHours,
            jobStatusCounts: JobFinalStatus.allCases.map {
                StatusCountResponse(status: $0.rawValue, count: statusCounts[$0.rawValue, default: 0])
            },
            queueWait: durationSummary(for: queueWaitValues),
            execution: durationSummary(for: executionValues),
            compatibility: compatibilitySnapshot
        )
    }

    func metricsTimeSeriesSnapshot(
        req: Request,
        hours requestedHours: Int?,
        bucketMinutes requestedBucketMinutes: Int?
    ) async throws -> InternalMetricsTimeSeriesResponse {
        let hours = min(max(requestedHours ?? configuration.recentMetricsWindowHours, 1), 72)
        let bucketMinutes = min(max(requestedBucketMinutes ?? 15, 1), 60)
        let now = Date()
        let windowStart = now.addingTimeInterval(Double(-hours) * 3600)
        let bucketSeconds = bucketMinutes * 60
        let bucketCount = max(1, Int(ceil(Double(hours * 3600) / Double(bucketSeconds))))

        let runnerSnapshots = try await RunnerSnapshot.query(on: req.db)
            .filter(\.$recordedAt >= windowStart)
            .sort(\.$recordedAt, .ascending)
            .all()

        let requestMetrics = try await APIRequestMetric.query(on: req.db)
            .filter(\.$finishedAt >= windowStart)
            .sort(\.$finishedAt, .ascending)
            .all()

        let jobMetrics = try await JobExecutionMetric.query(on: req.db)
            .filter(\.$completedAt >= windowStart)
            .sort(\.$completedAt, .ascending)
            .all()

        var runnerSamplesByBucket = Array(repeating: RunnerBucketAccumulator(), count: bucketCount)
        var requestSamplesByBucket = Array(repeating: RequestBucketAccumulator(), count: bucketCount)
        var jobSamplesByBucket = Array(repeating: JobBucketAccumulator(), count: bucketCount)

        for snapshot in runnerSnapshots {
            guard let bucketIndex = bucketIndex(
                for: snapshot.recordedAt,
                windowStart: windowStart,
                bucketSeconds: bucketSeconds,
                bucketCount: bucketCount
            ) else {
                continue
            }

            runnerSamplesByBucket[bucketIndex].sampleCount += 1
            runnerSamplesByBucket[bucketIndex].activeRunnerTotal += 1
            if snapshot.maxJobs > 0 {
                let utilization = Int((Double(snapshot.activeJobs) / Double(snapshot.maxJobs) * 100).rounded())
                runnerSamplesByBucket[bucketIndex].utilizationValues.append(min(100, max(0, utilization)))
            }
        }

        for metric in requestMetrics {
            guard let bucketIndex = bucketIndex(
                for: metric.finishedAt,
                windowStart: windowStart,
                bucketSeconds: bucketSeconds,
                bucketCount: bucketCount
            ) else {
                continue
            }

            requestSamplesByBucket[bucketIndex].requestCount += 1
            requestSamplesByBucket[bucketIndex].durationValues.append(metric.durationMs)
        }

        for metric in jobMetrics {
            guard let completedAt = metric.completedAt,
                  let bucketIndex = bucketIndex(
                    for: completedAt,
                    windowStart: windowStart,
                    bucketSeconds: bucketSeconds,
                    bucketCount: bucketCount
                  ) else {
                continue
            }

            jobSamplesByBucket[bucketIndex].completedJobs += 1
            if let queueWaitMs = metric.queueWaitMs {
                jobSamplesByBucket[bucketIndex].queueWaitValues.append(queueWaitMs)
            }
            if let executionMs = metric.executionMs {
                jobSamplesByBucket[bucketIndex].executionValues.append(executionMs)
            }

            switch metric.finalStatus {
            case JobFinalStatus.passed.rawValue:
                jobSamplesByBucket[bucketIndex].passedCount += 1
            case JobFinalStatus.failed.rawValue:
                jobSamplesByBucket[bucketIndex].failedCount += 1
            case JobFinalStatus.error.rawValue:
                jobSamplesByBucket[bucketIndex].errorCount += 1
            case JobFinalStatus.timeout.rawValue:
                jobSamplesByBucket[bucketIndex].timeoutCount += 1
            default:
                break
            }
        }

        let buckets = (0..<bucketCount).map { index in
            let runner = runnerSamplesByBucket[index]
            let request = requestSamplesByBucket[index]
            let jobs = jobSamplesByBucket[index]
            let avgActiveRunners = runner.sampleCount > 0
                ? Int((Double(runner.activeRunnerTotal) / Double(runner.sampleCount)).rounded())
                : 0

            return InternalMetricsBucketResponse(
                bucketStart: windowStart.addingTimeInterval(Double(index * bucketSeconds)),
                avgRunnerUtilizationPercent: average(runner.utilizationValues),
                maxRunnerUtilizationPercent: runner.utilizationValues.max(),
                avgActiveRunners: avgActiveRunners,
                requestCount: request.requestCount,
                requestP95Ms: percentile95(request.durationValues),
                completedJobs: jobs.completedJobs,
                passedCount: jobs.passedCount,
                failedCount: jobs.failedCount,
                errorCount: jobs.errorCount,
                timeoutCount: jobs.timeoutCount,
                queueWaitP95Ms: percentile95(jobs.queueWaitValues),
                executionP95Ms: percentile95(jobs.executionValues)
            )
        }

        return InternalMetricsTimeSeriesResponse(
            generatedAt: now,
            windowHours: hours,
            bucketMinutes: bucketMinutes,
            buckets: buckets
        )
    }

    func pruneNow(on db: Database, logger: Logger) async {
        guard configuration.enabled else { return }
        await performPrune(on: db, logger: logger, now: Date())
    }

    func recordRequestMetric(
        method: String,
        path: String,
        requestKind: String?,
        statusCode: Int,
        startedAt: Date,
        finishedAt: Date,
        durationMs: Int,
        submissionID: String?,
        workerID: String?,
        on db: Database,
        logger: Logger
    ) async {
        guard configuration.enabled else { return }
        guard shouldCaptureRequest(path: path) else { return }

        do {
            let metric = APIRequestMetric(
                method: method,
                path: path,
                requestKind: requestKind,
                statusCode: statusCode,
                startedAt: startedAt,
                finishedAt: finishedAt,
                durationMs: durationMs,
                submissionID: submissionID,
                workerID: workerID
            )
            try await metric.save(on: db)
        } catch {
            logger.warning("diagnostics_request_metric_failed", metadata: [
                "path": .string(path),
                "error": .string(String(describing: error)),
            ])
        }

        guard configuration.verboseRequestTiming || shouldAlwaysLogRequest(path: path) else { return }
        logger.info("request_completed", metadata: [
            "method": .string(method),
            "path": .string(path),
            "request_kind": .string(requestKind ?? ""),
            "status_code": .stringConvertible(statusCode),
            "duration_ms": .stringConvertible(durationMs),
            "submission_id": .string(submissionID ?? ""),
            "worker_id": .string(workerID ?? ""),
        ])
    }

    private func shouldCaptureRequest(path: String) -> Bool {
        configuration.verboseRequestTiming || shouldAlwaysLogRequest(path: path)
    }

    private func shouldAlwaysLogRequest(path: String) -> Bool {
        path.hasPrefix("/api/") || path.hasPrefix("/submissions/") || path.hasPrefix("/testsetups/")
    }
}

private struct SubmissionDiagnosticsContext {
    let courseID: UUID?
    let assignmentID: UUID?
}

private extension OperationalDiagnosticsService {
    func findOrCreateSubmissionDiagnostics(
        submission: APISubmission,
        context: SubmissionDiagnosticsContext,
        on db: Database
    ) async throws -> APISubmissionDiagnostics {
        if let existing = try await APISubmissionDiagnostics.find(submission.id, on: db) {
            if existing.courseID == nil { existing.courseID = context.courseID }
            if existing.assignmentID == nil { existing.assignmentID = context.assignmentID }
            if existing.submittedAt == nil { existing.submittedAt = submission.submittedAt }
            return existing
        }

        let created = APISubmissionDiagnostics(
            submissionID: submission.id ?? "",
            testSetupID: submission.testSetupID,
            courseID: context.courseID,
            assignmentID: context.assignmentID,
            kind: submission.kind,
            submittedAt: submission.submittedAt
        )
        try await created.save(on: db)
        return created
    }

    func findOrCreateJobExecutionMetric(
        submission: APISubmission,
        context: SubmissionDiagnosticsContext,
        on db: Database
    ) async throws -> JobExecutionMetric {
        if let existing = try await JobExecutionMetric.query(on: db)
            .filter(\.$submissionID == (submission.id ?? ""))
            .first() {
            return existing
        }

        let created = JobExecutionMetric(
            submissionID: submission.id ?? "",
            jobID: submission.id ?? "",
            testSetupID: submission.testSetupID,
            courseID: context.courseID,
            assignmentID: context.assignmentID,
            userID: submission.userID,
            runnerID: submission.workerID,
            kind: submission.kind,
            attemptNumber: submission.attemptNumber,
            enqueuedAt: submission.retestedAt ?? submission.submittedAt
        )
        try await created.save(on: db)
        return created
    }

    func loadSubmissionContext(for submission: APISubmission, on db: Database) async throws -> SubmissionDiagnosticsContext {
        let courseID = try await APITestSetup.find(submission.testSetupID, on: db)?.courseID

        let assignmentID: UUID?
        if submission.kind == APISubmission.Kind.validation, let submissionID = submission.id {
            assignmentID = try await APIAssignment.query(on: db)
                .filter(\.$validationSubmissionID == submissionID)
                .first()?
                .id
        } else {
            assignmentID = try await APIAssignment.query(on: db)
                .filter(\.$testSetupID == submission.testSetupID)
                .first()?
                .id
        }

        return SubmissionDiagnosticsContext(courseID: courseID, assignmentID: assignmentID)
    }

    func pendingQueueDepth(on db: Database) async throws -> Int {
        let pendingValidation = try await APISubmission.query(on: db)
            .filter(\.$status == "pending")
            .filter(\.$kind == APISubmission.Kind.validation)
            .count()

        let pendingStudents = try await APISubmission.query(on: db)
            .filter(\.$status == "pending")
            .filter(\.$kind == APISubmission.Kind.student)
            .all()

        let workerModeSetupIDs = try await workerModeTestSetupIDs(
            for: pendingStudents.map(\.testSetupID),
            on: db
        )
        let pendingWorkerStudents = pendingStudents.reduce(into: 0) { count, submission in
            if workerModeSetupIDs.contains(submission.testSetupID) {
                count += 1
            }
        }

        return pendingValidation + pendingWorkerStudents
    }

    func maxQueueDepthSince(windowStart: Date, now: Date, on db: Database) async throws -> Int {
        var relevantSubmissions: [String: APISubmission] = [:]

        for submission in try await APISubmission.query(on: db)
            .filter(\.$submittedAt >= windowStart)
            .all() {
            if let id = submission.id {
                relevantSubmissions[id] = submission
            }
        }

        for submission in try await APISubmission.query(on: db)
            .filter(\.$assignedAt >= windowStart)
            .all() {
            if let id = submission.id {
                relevantSubmissions[id] = submission
            }
        }

        for submission in try await APISubmission.query(on: db)
            .filter(\.$status == "pending")
            .all() {
            if let id = submission.id {
                relevantSubmissions[id] = submission
            }
        }

        let workerModeSetupIDs = try await workerModeTestSetupIDs(
            for: relevantSubmissions.values
                .filter { $0.kind == APISubmission.Kind.student }
                .map(\.testSetupID),
            on: db
        )

        var queueDepth = 0
        var maxQueueDepth = 0
        var events: [(date: Date, delta: Int)] = []

        for submission in relevantSubmissions.values {
            let isWorkerEligible =
                submission.kind == APISubmission.Kind.validation
                || (submission.kind == APISubmission.Kind.student && workerModeSetupIDs.contains(submission.testSetupID))
            guard isWorkerEligible, let submittedAt = submission.submittedAt else { continue }

            let assignedAt = submission.assignedAt
            if submittedAt < windowStart && (assignedAt == nil || assignedAt! > windowStart) {
                queueDepth += 1
            }
            if submittedAt >= windowStart && submittedAt <= now {
                events.append((submittedAt, 1))
            }
            if let assignedAt, assignedAt > windowStart && assignedAt <= now {
                events.append((assignedAt, -1))
            }
        }

        maxQueueDepth = queueDepth
        events.sort {
            if $0.date == $1.date {
                return $0.delta > $1.delta
            }
            return $0.date < $1.date
        }

        for event in events {
            queueDepth = max(0, queueDepth + event.delta)
            maxQueueDepth = max(maxQueueDepth, queueDepth)
        }

        return maxQueueDepth
    }

    func peakUtilizationPercent(from snapshots: [RunnerSnapshot]) -> Int? {
        peakLoad(from: snapshots).map { snapshot in
            guard snapshot.maxJobs > 0 else { return nil }
            return Int((Double(snapshot.activeJobs) / Double(snapshot.maxJobs) * 100).rounded())
        } ?? nil
    }

    func peakLoad(from snapshots: [RunnerSnapshot]) -> (activeJobs: Int, maxJobs: Int)? {
        var latestByBucketAndRunner: [Int: [String: (activeJobs: Int, maxJobs: Int)]] = [:]

        for snapshot in snapshots {
            let bucket = Int(snapshot.recordedAt.timeIntervalSince1970 / 60)
            latestByBucketAndRunner[bucket, default: [:]][snapshot.runnerID] = (
                activeJobs: max(0, snapshot.activeJobs),
                maxJobs: max(0, snapshot.maxJobs)
            )
        }

        return latestByBucketAndRunner.values.compactMap { runnerStates in
            let totalActiveJobs = runnerStates.values.reduce(0) { $0 + $1.activeJobs }
            let totalMaxJobs = runnerStates.values.reduce(0) { $0 + $1.maxJobs }
            guard totalMaxJobs > 0 else { return nil }
            return (activeJobs: totalActiveJobs, maxJobs: totalMaxJobs)
        }.max { lhs, rhs in
            let lhsRatio = Double(lhs.activeJobs) / Double(lhs.maxJobs)
            let rhsRatio = Double(rhs.activeJobs) / Double(rhs.maxJobs)
            if lhsRatio == rhsRatio {
                return lhs.activeJobs < rhs.activeJobs
            }
            return lhsRatio < rhsRatio
        }
    }

    func bucketIndex(
        for date: Date,
        windowStart: Date,
        bucketSeconds: Int,
        bucketCount: Int
    ) -> Int? {
        let delta = Int(date.timeIntervalSince(windowStart))
        guard delta >= 0 else { return nil }
        let index = delta / bucketSeconds
        guard index >= 0, index < bucketCount else { return nil }
        return index
    }

    func inFlightJobCount(on db: Database) async throws -> Int {
        try await APISubmission.query(on: db)
            .group(.or) { group in
                group.filter(\.$status == "assigned")
                group.filter(\.$status == "running")
            }
            .count()
    }

    func durationSummary(for values: [Int]) -> DurationSummaryResponse {
        guard !values.isEmpty else {
            return DurationSummaryResponse(averageMs: nil, p50Ms: nil, p95Ms: nil)
        }
        let sorted = values.sorted()
        let average = sorted.reduce(0, +) / sorted.count
        return DurationSummaryResponse(
            averageMs: average,
            p50Ms: percentile(sorted, percentile: 0.50),
            p95Ms: percentile(sorted, percentile: 0.95)
        )
    }

    func percentile(_ sortedValues: [Int], percentile: Double) -> Int? {
        guard !sortedValues.isEmpty else { return nil }
        let index = min(sortedValues.count - 1, max(0, Int(Double(sortedValues.count - 1) * percentile)))
        return sortedValues[index]
    }

    func average(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / values.count
    }

    func percentile95(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return percentile(values.sorted(), percentile: 0.95)
    }

    func skippedCount(in outcomes: [TestOutcome]) -> Int {
        outcomes.filter { $0.shortResult.localizedCaseInsensitiveContains("skipped:") }.count
    }

    func normalizedTestID(for outcome: TestOutcome) -> String {
        let classPart = outcome.testClass?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if classPart.isEmpty { return outcome.testName }
        return "\(classPart).\(outcome.testName)"
    }

    func compactSummary(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(160))
    }

    func pruneIfNeeded(on db: Database, logger: Logger) async throws {
        let now = Date()
        guard await maintenance.shouldPrune(now: now, intervalHours: configuration.pruneIntervalHours) else {
            return
        }
        await performPrune(on: db, logger: logger, now: now)
    }

    func performPrune(on db: Database, logger: Logger, now: Date) async {
        do {
            let jobCutoff = now.addingTimeInterval(Double(-configuration.jobMetricRetentionDays) * 86400)
            let runnerCutoff = now.addingTimeInterval(Double(-configuration.runnerSnapshotRetentionDays) * 86400)

            try await JobExecutionMetric.query(on: db)
                .filter(\.$completedAt < jobCutoff)
                .delete()
            try await RunnerSnapshot.query(on: db)
                .filter(\.$recordedAt < runnerCutoff)
                .delete()
            try await APIRequestMetric.query(on: db)
                .filter(\.$finishedAt < jobCutoff)
                .delete()
            try await APISubmissionDiagnostics.query(on: db)
                .filter(\.$finishedAt < jobCutoff)
                .delete()

            await maintenance.markPruned(at: now)
            logger.info("observability_prune_complete", metadata: [
                "job_metric_retention_days": .stringConvertible(configuration.jobMetricRetentionDays),
                "runner_snapshot_retention_days": .stringConvertible(configuration.runnerSnapshotRetentionDays),
            ])
        } catch {
            logger.warning("observability_prune_failed", metadata: [
                "error": .string(String(describing: error)),
            ])
        }
    }

    func logMetadata(
        event: ObservabilityEvent,
        submission: APISubmission,
        context: SubmissionDiagnosticsContext,
        extra: Logger.Metadata = [:]
    ) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "timestamp": iso8601Metadata(Date()),
            "event": .string(event.rawValue),
            "submission_id": .string(submission.id ?? ""),
            "job_id": .string(submission.id ?? ""),
            "runner_id": .string(submission.workerID ?? ""),
            "course_id": .string(context.courseID?.uuidString ?? ""),
            "assignment_id": .string(context.assignmentID?.uuidString ?? ""),
            "user_id": .string(submission.userID?.uuidString ?? ""),
            "test_setup_id": .string(submission.testSetupID),
            "attempt_number": submission.attemptNumber.map { .stringConvertible($0) } ?? .string(""),
            "kind": .string(submission.kind),
        ]
        for (key, value) in extra {
            metadata[key] = value
        }
        return metadata
    }

    func runnerMetadata(
        event: ObservabilityEvent,
        snapshot: WorkerActivitySnapshot,
        extra: Logger.Metadata = [:]
    ) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "timestamp": iso8601Metadata(Date()),
            "event": .string(event.rawValue),
            "runner_id": .string(snapshot.workerID),
            "hostname": .string(snapshot.hostname),
            "runner_version": .string(snapshot.runnerVersion),
            "runner_active_jobs": .stringConvertible(snapshot.activeJobs),
            "max_jobs": .stringConvertible(snapshot.maxConcurrentJobs),
            "last_poll_at": snapshot.lastPollAt.map(iso8601Metadata) ?? .string(""),
            "last_heartbeat_at": snapshot.lastHeartbeatAt.map(iso8601Metadata) ?? .string(""),
            "server_assigned_job_count_since_start": .stringConvertible(snapshot.serverAssignedJobCountSinceStart),
        ]
        for (key, value) in extra {
            metadata[key] = value
        }
        return metadata
    }

    func compatibilityMetadata(
        event: ObservabilityEvent,
        submission: APISubmission,
        assignmentID: UUID?,
        runnerID: String?,
        requirements: AssignmentRequirementSpec?,
        extra: Logger.Metadata = [:]
    ) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "timestamp": iso8601Metadata(Date()),
            "event": .string(event.rawValue),
            "submission_id": .string(submission.id ?? ""),
            "job_id": .string(submission.id ?? ""),
            "assignment_id": .string(assignmentID?.uuidString ?? ""),
            "runner_id": .string(runnerID ?? submission.workerID ?? ""),
            "requirement_summary": .string(requirementSummary(requirements)),
        ]
        for (key, value) in extra {
            metadata[key] = value
        }
        return metadata
    }

    func requirementSummary(_ requirements: AssignmentRequirementSpec?) -> String {
        guard let requirements else { return "none" }
        var parts: [String] = []
        if let platform = requirements.requiredPlatform, !platform.isEmpty {
            parts.append("platform=\(platform)")
        }
        if let architecture = requirements.requiredArchitecture, !architecture.isEmpty {
            parts.append("architecture=\(architecture)")
        }
        if !requirements.requiredLanguages.isEmpty {
            parts.append(
                "languages=" + requirements.requiredLanguages.map {
                    let min = $0.minimumVersion.map { ">=" + $0 } ?? ""
                    let exact = $0.exactVersion.map { "==" + $0 } ?? ""
                    return $0.language + min + exact
                }.joined(separator: ",")
            )
        }
        if !requirements.requiredCapabilities.isEmpty {
            parts.append("capabilities=" + requirements.requiredCapabilities.map(\.name).joined(separator: ","))
        }
        return parts.isEmpty ? "none" : parts.joined(separator: " ")
    }
}

extension OperationalDiagnosticsService {
    func workerModeTestSetupIDs(for testSetupIDs: [String], on db: Database) async throws -> Set<String> {
        var result: Set<String> = []

        for testSetupID in Set(testSetupIDs) {
            guard let setup = try await APITestSetup.find(testSetupID, on: db) else { continue }
            let data = Data(setup.manifest.utf8)
            guard
                let manifest = try? JSONDecoder().decode(TestProperties.self, from: data),
                manifest.gradingMode == .worker
            else { continue }
            result.insert(testSetupID)
        }

        return result
    }
}

func inferredFinalStatus(from collection: TestOutcomeCollection) -> JobFinalStatus {
    if collection.timeoutCount > 0 { return .timeout }
    if collection.errorCount > 0 { return .error }
    if collection.buildStatus == .failed || collection.failCount > 0 { return .failed }
    return .passed
}

func inferredTerminationReason(from collection: TestOutcomeCollection) -> String {
    if collection.timeoutCount > 0 { return "test_timeout" }
    if collection.errorCount > 0 { return "test_error" }
    if collection.failCount > 0 || collection.buildStatus == .failed { return "test_failure" }
    return "completed"
}

private func millisecondsBetween(_ start: Date?, _ end: Date?) -> Int? {
    guard let start, let end else { return nil }
    guard end >= start else { return nil }
    return Int((end.timeIntervalSince(start) * 1000).rounded())
}

private func iso8601Metadata(_ date: Date) -> Logger.MetadataValue {
    .string(ISO8601DateFormatter().string(from: date))
}

private func environmentInt(_ key: String) -> Int? {
    guard let raw = Environment.get(key)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        let value = Int(raw) else {
        return nil
    }
    return value
}

struct DiagnosticsConfigurationKey: StorageKey {
    typealias Value = DiagnosticsConfiguration
}

struct OperationalDiagnosticsServiceKey: StorageKey {
    typealias Value = OperationalDiagnosticsService
}

struct ObservabilityLifecycleHandler: LifecycleHandler {
    func didBoot(_ application: Application) throws {
        Task {
            await application.diagnostics.pruneNow(on: application.db, logger: application.logger)
        }
    }
}

extension Application {
    var diagnosticsConfiguration: DiagnosticsConfiguration {
        get {
            if let existing = storage[DiagnosticsConfigurationKey.self] { return existing }
            let created = DiagnosticsConfiguration.fromEnvironment()
            storage[DiagnosticsConfigurationKey.self] = created
            return created
        }
        set { storage[DiagnosticsConfigurationKey.self] = newValue }
    }

    var diagnostics: OperationalDiagnosticsService {
        get {
            if let existing = storage[OperationalDiagnosticsServiceKey.self] { return existing }
            let created = OperationalDiagnosticsService(configuration: diagnosticsConfiguration)
            storage[OperationalDiagnosticsServiceKey.self] = created
            return created
        }
        set { storage[OperationalDiagnosticsServiceKey.self] = newValue }
    }
}
