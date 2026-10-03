// Worker/RunnerDaemon+JobReporting.swift
//
// The report phase of a job: the execution diagnostics and the report to the
// server. Split from RunnerDaemon+JobProcessing.swift (#1799).

import Core
import Foundation

extension WorkerDaemon {

    func makeExecutionDiagnostics(
        collection: TestOutcomeCollection,
        jobStartedAt: Date,
        stageTimings: JobStageTimings,
        disk: JobDiskReadings
    ) -> WorkerExecutionDiagnostics {
        WorkerExecutionDiagnostics(
            runnerID: workerID,
            startedAt: jobStartedAt,
            finishedAt: collection.timestamp,
            finalStatus: Self.inferredCollectionStatus(collection).rawValue,
            timedOut: collection.timeoutCount > 0,
            exitCode: nil,
            terminationReason: nil,
            peakRSSBytes: nil,
            wallClockMs: collection.executionTimeMs,
            childProcessCount: nil,
            stdoutBytes: nil,
            stderrBytes: nil,
            stageTimings: stageTimings.asWorkerExecutionStageTimings(),
            freeDiskMBAtStart: disk.freeMBAtStart,
            freeDiskMBAtEnd: disk.freeMBAtEnd,
            workdirPeakBytes: disk.workdirPeakBytes
        )
    }

    func reportJobResult(
        job: Job,
        collection: TestOutcomeCollection,
        diagnostics: WorkerExecutionDiagnostics,
        matches: [MatchReport]?,
        stageTimings: inout JobStageTimings
    ) async throws {
        do {
            let resultReportStartedAt = Date()
            // Shielded from cancellation (SE-0504). `run()` fans the slots out
            // under `withThrowingDiscardingTaskGroup`, so one slot throwing a
            // non-retryable error cancels its siblings mid-job. Before the
            // shield that cancelled this call, and the grading work was simply
            // discarded: the submission stayed `assigned` until
            // `reapStuckAssignedSubmissions` aged it out, which is a ten-minute
            // wait for a student whose result the runner was already holding.
            // The report is bounded by the reporter's own network timeouts, so
            // shielding it delays shutdown by that much at most.
            try await withTaskCancellationShield {
                try await reporter.report(
                    WorkerExecutionReport(collection: collection, diagnostics: diagnostics, matches: matches))
            }
            stageTimings.record(
                "result_report",
                milliseconds: Int(Date().timeIntervalSince(resultReportStartedAt) * 1000)
            )
            writeStructuredRunnerLog(
                event: "result_submission_succeeded",
                fields: [
                    "runner_id": workerID,
                    "submission_id": job.submissionID,
                    "status": Self.inferredCollectionStatus(collection).rawValue,
                ])
        } catch {
            writeStructuredRunnerLog(
                event: "result_submission_failed",
                fields: [
                    "runner_id": workerID,
                    "submission_id": job.submissionID,
                    "error_type": String(describing: type(of: error)),
                    "error_message_summary": String(describing: error),
                ])
            throw error
        }
    }
}
