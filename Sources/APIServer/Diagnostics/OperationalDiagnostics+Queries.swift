// Sources/APIServer/Diagnostics/OperationalDiagnostics+Queries.swift
//
// Query/projection helpers used by the Recording and Metrics extensions.
// These were a `private extension` in the original monolithic file;
// promoted to internal so the split files can call across.

import Core
import Fluent
import Foundation
import SQLKit
import Vapor

/// One row of the grouped pending count in `pendingQueueDepth`.
private struct PendingKindSetupCountRow: Decodable {
    let kind: String
    let testSetupID: String
    let total: Int

    enum CodingKeys: String, CodingKey {
        case kind
        case testSetupID = "test_setup_id"
        case total
    }
}

/// What `pendingQueueDepth` counts, and how many pending rows it read to
/// count it.
private struct PendingQueueDepthCount {
    let depth: Int
    let countedRows: Int
}

extension OperationalDiagnosticsService {

    /// The submission's diagnostics row, or a new one NOT yet saved. Every
    /// caller fills in fields and saves, so a new row costs one INSERT rather
    /// than an INSERT and then an UPDATE.
    func findOrMakeSubmissionDiagnostics(
        submission: APISubmission,
        context: SubmissionDiagnosticsContext,
        on db: any Database
    ) async throws -> APISubmissionDiagnostics {
        if let existing = try await APISubmissionDiagnostics.find(submission.id, on: db) {
            if existing.courseID == nil { existing.courseID = context.courseID }
            if existing.assignmentID == nil { existing.assignmentID = context.assignmentID }
            if existing.submittedAt == nil { existing.submittedAt = submission.submittedAt }
            return existing
        }

        return APISubmissionDiagnostics(
            submissionID: submission.id ?? "",
            testSetupID: submission.testSetupID,
            courseID: context.courseID,
            assignmentID: context.assignmentID,
            kind: submission.kind,
            submittedAt: submission.submittedAt
        )
    }

    /// The submission's metric row, or a new one NOT yet saved, like
    /// `findOrMakeSubmissionDiagnostics`.
    func findOrMakeJobExecutionMetric(
        submission: APISubmission,
        context: SubmissionDiagnosticsContext,
        on db: any Database
    ) async throws -> JobExecutionMetric {
        if let existing = try await JobExecutionMetric.query(on: db)
            .filter(\.$submissionID == (submission.id ?? ""))
            .first()
        {
            return existing
        }

        return JobExecutionMetric(
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
    }

    func loadSubmissionContext(
        for submission: APISubmission, on db: any Database
    ) async throws -> SubmissionDiagnosticsContext {
        let courseID = try await APITestSetup.find(submission.testSetupID, on: db)?.courseID

        let assignmentID: UUID?
        if submission.kind == APISubmission.Kind.validation, let submissionID = submission.id {
            assignmentID = try await APIAssignment.query(on: db)
                .filter(\.$validationSubmissionID == submissionID)
                .first()?
                .id
        } else {
            assignmentID = try await assignmentByTestSetupID(submission.testSetupID, on: db)?
                .id
        }

        return SubmissionDiagnosticsContext(courseID: courseID, assignmentID: assignmentID)
    }

    /// Pending jobs the native worker fleet is on the hook for: every pending
    /// validation, plus pending student work whose assignment is not
    /// browser-graded.
    ///
    /// Its round trips and memory scale with the number of *distinct
    /// assignments* holding pending work, never with queue depth. This used to
    /// load every pending student row into memory to produce one log field,
    /// which made each claim and each submission-accept slower exactly as the
    /// backlog grew — the wrong direction under pressure, and unbounded after a
    /// retest fan-out flips tens of thousands of rows back to pending (#1361).
    ///
    /// The database still reads every pending row to count them (7 to 10 ms
    /// at a 25,000-row backlog), so the per-event `queue_depth` log field goes
    /// through `queueDepthForLog(on:)` instead. This one is always exact.
    func pendingQueueDepth(on db: any Database) async throws -> Int {
        try await countPendingQueueDepth(on: db).depth
    }

    /// The `queue_depth` field of the `job_enqueued` and `job_assigned` log
    /// lines: `pendingQueueDepth(on:)`, except that while the backlog is
    /// large a count from the last few seconds is reused
    /// (`QueueDepthLogSampleStore`). Nothing else may read it.
    func queueDepthForLog(on db: any Database) async throws -> Int {
        let now = ContinuousClock.now
        if let depth = await queueDepthLogSampler.reusableDepth(at: now) {
            return depth
        }
        let count = try await countPendingQueueDepth(on: db)
        await queueDepthLogSampler.record(depth: count.depth, countedRows: count.countedRows, takenAt: now)
        return count.depth
    }

    /// `queueDepthForLog(on:)` for a line that `logger` writes at info, or nil
    /// when `logger` drops info lines. Only info lines carry the depth, so a
    /// server run at `notice` (Vapor's production default when `LOG_LEVEL`
    /// is unset) needs no count at all.
    func queueDepthForLog(on db: any Database, logger: Logger) async throws -> Int? {
        guard logger.logLevel <= .info else { return nil }
        return try await queueDepthForLog(on: db)
    }

    /// `pendingQueueDepth(on:)`, with the number of pending rows the count
    /// read: the cost that `queueDepthForLog(on:)` decides on.
    private func countPendingQueueDepth(on db: any Database) async throws -> PendingQueueDepthCount {
        // A starter run (NB8) is a runner job like a solution run.
        let validationKinds = [APISubmission.Kind.validation, APISubmission.Kind.starterValidation]

        // One grouped count answers both halves: the pending validation total
        // and the pending student count per setup, which the browser-graded
        // filter below needs. It replaces a validation count, a DISTINCT
        // setup read and a second student count.
        var pendingValidation = 0
        var pendingStudentsBySetupID: [String: Int] = [:]
        if let sql = db as? (any SQLDatabase) {
            let rows = try await sql.select()
                .column("kind")
                .column("test_setup_id")
                .column(SQLFunction("COUNT", args: SQLLiteral.all), as: "total")
                .from(APISubmission.schema)
                .where("status", .equal, SubmissionStatus.pending.rawValue)
                .where("kind", .in, [APISubmission.Kind.student] + validationKinds)
                .groupBy("kind")
                .groupBy("test_setup_id")
                .all(decoding: PendingKindSetupCountRow.self)
            for row in rows {
                if row.kind == APISubmission.Kind.student {
                    pendingStudentsBySetupID[row.testSetupID, default: 0] += row.total
                } else {
                    pendingValidation += row.total
                }
            }
        } else {
            pendingValidation = try await APISubmission.query(on: db)
                .filter(\.$status == SubmissionStatus.pending.rawValue)
                .filter(\.$kind ~~ validationKinds)
                .count()
            for setupID in try await APISubmission.query(on: db)
                .filter(\.$status == SubmissionStatus.pending.rawValue)
                .filter(\.$kind == APISubmission.Kind.student)
                .all(\.$testSetupID)
            {
                pendingStudentsBySetupID[setupID, default: 0] += 1
            }
        }
        let countedRows = pendingStudentsBySetupID.values.reduce(pendingValidation, +)
        guard !pendingStudentsBySetupID.isEmpty else {
            return PendingQueueDepthCount(depth: pendingValidation, countedRows: countedRows)
        }

        let workerModeSetupIDs = try await workerModeTestSetupIDs(
            for: Array(pendingStudentsBySetupID.keys),
            on: db
        )
        let pendingWorkerStudents = pendingStudentsBySetupID.reduce(0) { total, entry in
            workerModeSetupIDs.contains(entry.key) ? total + entry.value : total
        }
        return PendingQueueDepthCount(depth: pendingValidation + pendingWorkerStudents, countedRows: countedRows)
    }

    func maxQueueDepthSince(windowStart: Date, now: Date, on db: any Database) async throws -> Int {
        let timeline = try await queueDepthTimeline(windowStart: windowStart, now: now, on: db)
        return MetricsCardAccumulators.maxQueueDepth(timeline: timeline)
    }

    /// Builds the worker-eligible queue depth as an event timeline: the depth
    /// at `windowStart` plus the sorted ±1 steps inside the window.  Shared
    /// by `maxQueueDepthSince` (single peak) and the card sparkline series
    /// (per-bucket peaks).
    func queueDepthTimeline(
        windowStart: Date,
        now: Date,
        on db: any Database
    ) async throws -> QueueDepthTimeline {
        var relevantSubmissions: [String: APISubmission] = [:]

        for submission in try await APISubmission.query(on: db)
            .filter(\.$submittedAt >= windowStart)
            .all()
        {
            if let id = submission.id {
                relevantSubmissions[id] = submission
            }
        }

        for submission in try await APISubmission.query(on: db)
            .filter(\.$assignedAt >= windowStart)
            .all()
        {
            if let id = submission.id {
                relevantSubmissions[id] = submission
            }
        }

        for submission in try await APISubmission.query(on: db)
            .filter(\.$status == SubmissionStatus.pending.rawValue)
            .all()
        {
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

        var initialDepth = 0
        var events: [QueueDepthEvent] = []

        for submission in relevantSubmissions.values {
            let isWorkerEligible =
                submission.kind == APISubmission.Kind.validation
                || submission.kind == APISubmission.Kind.starterValidation
                || (submission.kind == APISubmission.Kind.student
                    && workerModeSetupIDs.contains(submission.testSetupID))
            guard isWorkerEligible, let submittedAt = submission.submittedAt else { continue }

            let assignedAt = submission.assignedAt
            // Pending at windowStart: submitted before the window opened AND
            // either never assigned, or assigned after the window opened.
            if submittedAt < windowStart, (assignedAt ?? .distantFuture) > windowStart {
                initialDepth += 1
            }
            if submittedAt >= windowStart && submittedAt <= now {
                events.append(QueueDepthEvent(date: submittedAt, delta: 1))
            }
            if let assignedAt, assignedAt > windowStart && assignedAt <= now {
                events.append(QueueDepthEvent(date: assignedAt, delta: -1))
            }
        }

        events.sort {
            if $0.date == $1.date {
                return $0.delta > $1.delta
            }
            return $0.date < $1.date
        }

        return QueueDepthTimeline(initialDepth: initialDepth, events: events)
    }

    func inFlightJobCount(on db: any Database) async throws -> Int {
        try await APISubmission.query(on: db)
            .group(.or) { group in
                group.filter(\.$status == SubmissionStatus.assigned.rawValue)
                group.filter(\.$status == SubmissionStatus.running.rawValue)
            }
            .count()
    }

    func durationSummary(for values: [Int]) -> DurationSummaryResponse {
        guard !values.isEmpty else {
            return DurationSummaryResponse(averageMs: nil, p50Ms: nil, p95Ms: nil)
        }
        let sorted = values.sorted()
        return DurationSummaryResponse(
            averageMs: MetricBucketAccumulators.average(sorted),
            p50Ms: MetricBucketAccumulators.percentile(sorted, percentile: 0.50),
            p95Ms: MetricBucketAccumulators.percentile(sorted, percentile: 0.95)
        )
    }

    func skippedCount(in outcomes: [TestOutcome]) -> Int {
        outcomes.count(where: { $0.shortResult.localizedCaseInsensitiveContains("skipped:") })
    }

    func normalizedTestID(for outcome: TestOutcome) -> String {
        let classPart = outcome.testClass?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if classPart.isEmpty { return outcome.testName }
        return "\(classPart).\(outcome.testName)"
    }

    func compactSummary(_ text: String) -> String {
        let collapsed =
            text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(160))
    }

    func performPrune(on db: any Database, logger: Logger, now: Date) async {
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
            // Rows whose job never reported completion keep a NULL
            // finished_at, which `< cutoff` never matches — so they used to
            // accumulate permanently (#1382 item 8). Age them out on
            // created_at at the same window: once a full retention period has
            // passed, the job is not going to finish, and the row's value as
            // a stuck-job breadcrumb has long been superseded by the health
            // alerts and logs from the incident itself.
            try await APISubmissionDiagnostics.query(on: db)
                .filter(\.$finishedAt == nil)
                .filter(\.$createdAt < jobCutoff)
                .delete()
            // Browser-side telemetry: one row per JS error, kernel boot failure
            // and grading failover, each carrying a message and a stack. It was
            // the only diagnostics table with no retention at all, while being
            // the highest-volume endpoint the server takes — and it grows
            // fastest during exactly the incident that makes someone read it.
            // Same window as the rest; `idx_client_diagnostics_created_at`
            // already covers the predicate (#1365).
            try await APIClientDiagnostic.query(on: db)
                .filter(\.$createdAt < jobCutoff)
                .delete()

            logger.info(
                "observability_prune_complete",
                metadata: [
                    "job_metric_retention_days": .stringConvertible(configuration.jobMetricRetentionDays),
                    "runner_snapshot_retention_days": .stringConvertible(configuration.runnerSnapshotRetentionDays),
                ])
        } catch {
            logger.warning(
                "observability_prune_failed",
                metadata: [
                    "error": .string(String(describing: error))
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
                "languages="
                    + requirements.requiredLanguages.map {
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
