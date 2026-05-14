// Sources/APIServer/Diagnostics/OperationalDiagnostics+Queries.swift
//
// Query/projection helpers used by the Recording and Metrics extensions.
// These were a `private extension` in the original monolithic file;
// promoted to internal so the split files can call across.

import Core
import Fluent
import Foundation
import Vapor

extension OperationalDiagnosticsService {

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
            .first()
        {
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

    func loadSubmissionContext(
        for submission: APISubmission, on db: Database
    ) async throws -> SubmissionDiagnosticsContext {
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
            .filter(\.$status == "pending")
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

        var queueDepth = 0
        var maxQueueDepth = 0
        var events: [(date: Date, delta: Int)] = []

        for submission in relevantSubmissions.values {
            let isWorkerEligible =
                submission.kind == APISubmission.Kind.validation
                || (submission.kind == APISubmission.Kind.student
                    && workerModeSetupIDs.contains(submission.testSetupID))
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
        return DurationSummaryResponse(
            averageMs: MetricBucketAccumulators.average(sorted),
            p50Ms: MetricBucketAccumulators.percentile(sorted, percentile: 0.50),
            p95Ms: MetricBucketAccumulators.percentile(sorted, percentile: 0.95)
        )
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
        let collapsed =
            text
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
