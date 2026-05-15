// Sources/APIServer/Diagnostics/OperationalDiagnostics+Recording.swift
//
// Event-recording extensions on OperationalDiagnosticsService.  Each
// method is invoked at one well-defined point in the submission /
// runner lifecycle and persists structured diagnostics plus a log
// event.  Split from OperationalDiagnostics.swift for navigability.

import Core
import Fluent
import Foundation
import Vapor

extension OperationalDiagnosticsService {

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
            logger.warning(
                "diagnostics_submission_create_failed",
                metadata: [
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
                        "available_capacity": .stringConvertible(
                            max(0, snapshot.maxConcurrentJobs - snapshot.activeJobs)),
                    ]
                )
            )
            try await pruneIfNeeded(on: db, logger: logger)
        } catch {
            logger.warning(
                "diagnostics_runner_snapshot_failed",
                metadata: [
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
                "languages": .string(
                    capabilityProfile.languageVersions.map {
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
                    "status": .string("loaded")
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
                    "status": .string("assigned")
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
            // Re-baseline the queue clock on retests so queue-wait reflects
            // the retest window, not the time since the original submission.
            // Matches the v0.4.45 fix already applied to APISubmissionDiagnostics
            // (`effectiveEnqueuedAt`). Non-retests have `retestedAt == nil` so
            // this is a no-op for them.
            metric.enqueuedAt = submission.retestedAt ?? submission.submittedAt ?? metric.enqueuedAt

            // If this row already carries data from a finished attempt (the
            // retest case), clear the per-attempt fields so the in-flight
            // retest doesn't render with mixed timestamps (which made
            // `Total < Queue Wait` show up on the admin runner page).
            // `recordWorkerExecutionReport` will repopulate them when the
            // retest completes.
            if metric.completedAt != nil {
                metric.startedAt = nil
                metric.completedAt = nil
                metric.executionMs = nil
                metric.totalProcessingMs = nil
                metric.finalStatus = nil
                metric.testsPassed = nil
                metric.testsFailed = nil
                metric.testsErrored = nil
                metric.testsTimedOut = nil
                metric.skippedCount = nil
                metric.workdirSetupMs = nil
                metric.submissionDirSetupMs = nil
                metric.submissionDownloadMs = nil
                metric.testSetupAcquireMs = nil
                metric.submissionUnpackMs = nil
                metric.starterCleanupMs = nil
                metric.submissionPrepareMs = nil
                metric.makeStepMs = nil
                metric.runtimeHelperSetupMs = nil
                metric.testExecutionMs = nil
                metric.testSetupCacheHit = nil
                metric.freeDiskMBAtStart = nil
                metric.freeDiskMBAtEnd = nil
                metric.workdirPeakBytes = nil
            }

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
            logger.warning(
                "diagnostics_job_assign_failed",
                metadata: [
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
                logger.warning(
                    "diagnostics_missing_submission",
                    metadata: [
                        "submission_id": .string(collection.submissionID)
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
            let startedAt =
                workerDiagnostics?.startedAt ?? collection.jobStartedAt ?? diagnostics.startedAt
                ?? submission.assignedAt
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
            diagnostics.executionMs =
                workerDiagnostics?.wallClockMs
                ?? millisecondsBetween(startedAt, completedAt)
            diagnostics.turnaroundMs = millisecondsBetween(effectiveEnqueuedAt, completedAt)
            diagnostics.finalStatus = finalStatus
            diagnostics.timedOut = finalStatus == JobFinalStatus.timeout.rawValue
            diagnostics.exitCode = workerDiagnostics?.exitCode
            diagnostics.terminationReason =
                workerDiagnostics?.terminationReason
                ?? inferredTerminationReason(from: collection)
            diagnostics.peakRSSBytes = workerDiagnostics?.peakRSSBytes
            diagnostics.wallClockMs = workerDiagnostics?.wallClockMs
            diagnostics.childProcessCount = workerDiagnostics?.childProcessCount
            diagnostics.stdoutBytes = workerDiagnostics?.stdoutBytes
            diagnostics.stderrBytes = workerDiagnostics?.stderrBytes
            diagnostics.freeDiskMBAtStart = workerDiagnostics?.freeDiskMBAtStart
            diagnostics.freeDiskMBAtEnd = workerDiagnostics?.freeDiskMBAtEnd
            diagnostics.workdirPeakBytes = workerDiagnostics?.workdirPeakBytes
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
            StageTimingAggregator(from: workerDiagnostics?.stageTimings).apply(to: metric)
            metric.finalStatus = finalStatus
            metric.testsPassed = collection.passCount
            metric.testsFailed = collection.failCount
            metric.testsErrored = collection.errorCount
            metric.testsTimedOut = collection.timeoutCount
            metric.skippedCount = skippedCount(in: collection.outcomes)
            metric.freeDiskMBAtStart = workerDiagnostics?.freeDiskMBAtStart
            metric.freeDiskMBAtEnd = workerDiagnostics?.freeDiskMBAtEnd
            metric.workdirPeakBytes = workerDiagnostics?.workdirPeakBytes
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
            logger.warning(
                "diagnostics_job_finish_failed",
                metadata: [
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
            diagnostics.finalStatus =
                terminationReason == "job_timeout"
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
            metric.finalStatus =
                terminationReason == "job_timeout"
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
            logger.warning(
                "diagnostics_job_failure_record_failed",
                metadata: [
                    "submission_id": .string(submissionID),
                    "error": .string(String(describing: error)),
                ])
        }
    }
}
