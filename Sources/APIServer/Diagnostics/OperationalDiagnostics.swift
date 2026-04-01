import Core
import Fluent
import Vapor
import Foundation

struct RunnerAverages: Sendable {
    let avgExecutionMs: Int?
    let avgQueueWaitMs: Int?
}

struct DiagnosticsConfiguration: Sendable {
    let enabled: Bool
    let verboseRequestTiming: Bool

    static func fromEnvironment() -> Self {
        Self(
            enabled: environmentBool("ENABLE_DIAGNOSTICS_COLLECTION") ?? true,
            verboseRequestTiming: environmentBool("VERBOSE_REQUEST_TIMING") ?? false
        )
    }
}

final class OperationalDiagnosticsService: @unchecked Sendable {
    let configuration: DiagnosticsConfiguration

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
            logger.info(
                Logger.Message(stringLiteral: "job_submitted"),
                metadata: jobMetadata(
                    submissionID: submissionID,
                    runnerID: nil,
                    courseID: context.courseID,
                    assignmentID: context.assignmentID,
                    testSetupID: submission.testSetupID,
                    extra: [
                        "kind": .string(submission.kind),
                        "submitted_at": diagnostics.submittedAt.map(iso8601Metadata) ?? .string(""),
                    ]
                )
            )
        } catch {
            logger.warning("diagnostics_submission_create_failed", metadata: [
                "submission_id": .string(submissionID),
                "error": .string(String(describing: error)),
            ])
        }
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
            logger.info(
                Logger.Message(stringLiteral: "job_assigned"),
                metadata: jobMetadata(
                    submissionID: submissionID,
                    runnerID: diagnostics.runnerID,
                    courseID: context.courseID,
                    assignmentID: context.assignmentID,
                    testSetupID: submission.testSetupID,
                    extra: [
                        "assigned_at": diagnostics.assignedAt.map(iso8601Metadata) ?? .string(""),
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

            diagnostics.submittedAt = submission.submittedAt ?? diagnostics.submittedAt
            diagnostics.assignedAt = submission.assignedAt ?? diagnostics.assignedAt
            diagnostics.runnerID = workerDiagnostics?.runnerID ?? submission.workerID ?? diagnostics.runnerID
            diagnostics.startedAt = workerDiagnostics?.startedAt ?? diagnostics.startedAt
            diagnostics.finishedAt = workerDiagnostics?.finishedAt ?? diagnostics.finishedAt
            diagnostics.queueWaitMs = millisecondsBetween(diagnostics.submittedAt, diagnostics.startedAt)
            diagnostics.executionMs = workerDiagnostics?.wallClockMs
                ?? millisecondsBetween(diagnostics.startedAt, diagnostics.finishedAt)
            diagnostics.turnaroundMs = millisecondsBetween(diagnostics.submittedAt, diagnostics.finishedAt)
            diagnostics.finalStatus = workerDiagnostics?.finalStatus ?? inferredFinalStatus(from: collection)
            diagnostics.timedOut = workerDiagnostics?.timedOut ?? (collection.timeoutCount > 0)
            diagnostics.exitCode = workerDiagnostics?.exitCode
            diagnostics.terminationReason = workerDiagnostics?.terminationReason
                ?? inferredTerminationReason(from: collection)
            diagnostics.peakRSSBytes = workerDiagnostics?.peakRSSBytes
            diagnostics.wallClockMs = workerDiagnostics?.wallClockMs
            diagnostics.childProcessCount = workerDiagnostics?.childProcessCount
            diagnostics.stdoutBytes = workerDiagnostics?.stdoutBytes
            diagnostics.stderrBytes = workerDiagnostics?.stderrBytes
            try await diagnostics.save(on: db)

            let event = diagnostics.timedOut == true
                ? "job_timed_out"
                : (diagnostics.finalStatus == "passed" ? "job_finished" : "job_failed")
            logger.info(
                Logger.Message(stringLiteral: event),
                metadata: jobMetadata(
                    submissionID: collection.submissionID,
                    runnerID: diagnostics.runnerID,
                    courseID: context.courseID,
                    assignmentID: context.assignmentID,
                    testSetupID: submission.testSetupID,
                    extra: [
                        "final_status": .string(diagnostics.finalStatus ?? ""),
                        "timed_out": .stringConvertible(diagnostics.timedOut ?? false),
                        "queue_wait_ms": diagnostics.queueWaitMs.map { .stringConvertible($0) } ?? .string(""),
                        "execution_ms": diagnostics.executionMs.map { .stringConvertible($0) } ?? .string(""),
                        "turnaround_ms": diagnostics.turnaroundMs.map { .stringConvertible($0) } ?? .string(""),
                        "termination_reason": .string(diagnostics.terminationReason ?? ""),
                        "peak_rss_bytes": diagnostics.peakRSSBytes.map { .stringConvertible($0) } ?? .string(""),
                        "stdout_bytes": diagnostics.stdoutBytes.map { .stringConvertible($0) } ?? .string(""),
                        "stderr_bytes": diagnostics.stderrBytes.map { .stringConvertible($0) } ?? .string(""),
                    ]
                )
            )
        } catch {
            logger.warning("diagnostics_job_finish_failed", metadata: [
                "submission_id": .string(collection.submissionID),
                "error": .string(String(describing: error)),
            ])
        }
    }

    /// Convenience wrapper for the common case where the server receives a
    /// `TestOutcomeCollection` from a runner and wants to record diagnostics
    /// without constructing a full `WorkerExecutionDiagnostics` value.
    /// Derives `wallClockMs` from `collection.executionTimeMs` and treats
    /// `submission.assignedAt` as a proxy for job-start time.
    func recordWorkerResult(
        collection: TestOutcomeCollection,
        submission: APISubmission,
        on db: Database,
        logger: Logger
    ) async {
        let finishedAt = Date()
        let workerDiag = WorkerExecutionDiagnostics(
            runnerID:          submission.workerID ?? "",
            startedAt:         submission.assignedAt,
            finishedAt:        finishedAt,
            finalStatus:       inferredFinalStatus(from: collection),
            timedOut:          collection.timeoutCount > 0,
            exitCode:          nil,
            terminationReason: inferredTerminationReason(from: collection),
            peakRSSBytes:      nil,
            wallClockMs:       collection.executionTimeMs,
            childProcessCount: nil,
            stdoutBytes:       nil,
            stderrBytes:       nil
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
            diagnostics.queueWaitMs = millisecondsBetween(diagnostics.submittedAt, diagnostics.startedAt)
            diagnostics.executionMs = millisecondsBetween(diagnostics.startedAt, diagnostics.finishedAt)
            diagnostics.turnaroundMs = millisecondsBetween(diagnostics.submittedAt, diagnostics.finishedAt)
            diagnostics.finalStatus = "failed"
            diagnostics.timedOut = terminationReason == "job_timeout"
            diagnostics.terminationReason = terminationReason
            try await diagnostics.save(on: db)

            logger.error(
                terminationReason == "job_timeout" ? "job_timed_out" : "job_failed",
                metadata: jobMetadata(
                    submissionID: submissionID,
                    runnerID: diagnostics.runnerID,
                    courseID: context.courseID,
                    assignmentID: context.assignmentID,
                    testSetupID: submission.testSetupID,
                    extra: [
                        "termination_reason": .string(terminationReason),
                        "queue_wait_ms": diagnostics.queueWaitMs.map { .stringConvertible($0) } ?? .string(""),
                        "execution_ms": diagnostics.executionMs.map { .stringConvertible($0) } ?? .string(""),
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

    // MARK: - Rolling average queries

    /// Per-runner averages over the most recent `sampleSize` completed jobs.
    /// Returns a map of runnerID → `(avgExecutionMs, avgQueueWaitMs)`, both
    /// optionals (nil when no data is available for that metric).
    func rollingAverages(
        for runnerIDs: [String],
        sampleSize: Int = 50,
        on db: Database
    ) async throws -> [String: RunnerAverages] {
        guard !runnerIDs.isEmpty else { return [:] }
        let recentDiags = try await APISubmissionDiagnostics.query(on: db)
            .filter(\.$runnerID ~~ runnerIDs)
            .sort(\.$createdAt, .descending)
            .limit(runnerIDs.count * sampleSize)
            .all()

        var execByRunner: [String: [Int]] = [:]
        var waitByRunner: [String: [Int]] = [:]
        for d in recentDiags {
            guard let rid = d.runnerID else { continue }
            if let ms = d.executionMs, execByRunner[rid, default: []].count < sampleSize {
                execByRunner[rid, default: []].append(ms)
            }
            if let ms = d.queueWaitMs, waitByRunner[rid, default: []].count < sampleSize {
                waitByRunner[rid, default: []].append(ms)
            }
        }

        var result: [String: RunnerAverages] = [:]
        for rid in runnerIDs {
            let exec = execByRunner[rid] ?? []
            let wait = waitByRunner[rid] ?? []
            let avgExec = exec.isEmpty ? nil : exec.reduce(0, +) / exec.count
            let avgWait = wait.isEmpty ? nil : wait.reduce(0, +) / wait.count
            result[rid] = RunnerAverages(avgExecutionMs: avgExec, avgQueueWaitMs: avgWait)
        }
        return result
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
}

func inferredFinalStatus(from collection: TestOutcomeCollection) -> String {
    if collection.buildStatus == .failed { return "failed" }
    if collection.timeoutCount > 0 { return "timeout" }
    if collection.errorCount > 0 { return "error" }
    if collection.failCount > 0 { return "failed" }
    return "passed"
}

func inferredTerminationReason(from collection: TestOutcomeCollection) -> String {
    if collection.timeoutCount > 0 { return "test_timeout" }
    if collection.errorCount > 0 { return "test_error" }
    if collection.failCount > 0 { return "test_failure" }
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

private func jobMetadata(
    submissionID: String,
    runnerID: String?,
    courseID: UUID?,
    assignmentID: UUID?,
    testSetupID: String,
    extra: Logger.Metadata = [:]
) -> Logger.Metadata {
    var metadata: Logger.Metadata = [
        "submission_id": .string(submissionID),
        "runner_id": .string(runnerID ?? ""),
        "course_id": .string(courseID?.uuidString ?? ""),
        "assignment_id": .string(assignmentID?.uuidString ?? ""),
        "test_setup_id": .string(testSetupID),
    ]
    for (key, value) in extra {
        metadata[key] = value
    }
    return metadata
}

struct DiagnosticsConfigurationKey: StorageKey {
    typealias Value = DiagnosticsConfiguration
}

struct OperationalDiagnosticsServiceKey: StorageKey {
    typealias Value = OperationalDiagnosticsService
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
