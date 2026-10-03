// Worker/RunnerDaemon+JobProcessing.swift
//
// The per-job pipeline for WorkerDaemon: `process(_:)` runs one job through
// its four phases, each in its own file (#1799):
//
// - workspace setup and teardown: `JobWorkspace.swift`;
// - prepare: `RunnerDaemon+JobPreparation.swift`;
// - execute: `RunnerDaemon+SuiteExecution.swift`;
// - report: `RunnerDaemon+JobReporting.swift`, with the collection built by
//   `makeCollection` in `CollectionAssembly.swift`.

import Core
import Foundation

extension WorkerDaemon {

    // MARK: - Job processing

    func process(_ job: Job) async throws {
        activeJobs += 1
        let jobStartedAt = Date()
        defer { activeJobs = max(0, activeJobs - 1) }
        var stageTimings = JobStageTimings()

        logJobAccepted(job)
        try? await sendHeartbeat()

        let heartbeatTask = startHeartbeatLoop()
        defer {
            heartbeatTask.cancel()
            // End-of-job heartbeat so the server's last-seen timestamp
            // advances even if this job took >30s.
            //
            // Awaited in the defer (SE-0493) rather than fired into an
            // unstructured Task: the old shape raced `process()` returning,
            // so the heartbeat could still be in flight while the worker
            // loop claimed the next job. Shielded (SE-0504) because an async
            // defer still observes cancellation, and the detached Task it
            // replaces did not inherit it -- without the shield, the one path
            // that most needs a final heartbeat (the cancelled worker loop)
            // would be the one path that skipped it.
            await withTaskCancellationShield {
                try? await self.sendHeartbeat()
            }
        }

        // The configured work root, not the system temp dir: a test script's
        // working directory must permit `exec` for a compiled language, and
        // `/tmp` is `noexec` on a hardened container.
        let tempRoot = workRoot
        var disk = JobDiskReadings(freeMBAtStart: freeSpaceMB(at: tempRoot))
        try ensureSufficientDiskSpace(tempRoot: tempRoot, freeDiskMBAtStart: disk.freeMBAtStart, job: job)

        let paths = try setupJobWorkspace(tempRoot: tempRoot, job: job, stageTimings: &stageTimings)

        defer {
            finalizeJobWorkspace(
                job: job,
                paths: paths,
                tempRoot: tempRoot,
                jobStartedAt: jobStartedAt,
                stageTimings: &stageTimings,
                disk: &disk
            )
        }

        let prepared = try await prepareJobWorkspace(
            job: job,
            paths: paths,
            stageTimings: &stageTimings
        )
        defer { removeWorkspaceItem(at: prepared.testSetupDir, label: "test_setup_dir", job: job) }

        let testExecutionStartedAt = Date()
        let (outcomes, matches) = try await executeTestSuites(
            manifest: prepared.manifest,
            testSetupDir: prepared.testSetupDir,
            opponentDir: prepared.opponentDir,
            opponentDirs: prepared.opponentDirs,
            job: job
        )
        stageTimings.record(
            "test_execution", milliseconds: Int(Date().timeIntervalSince(testExecutionStartedAt) * 1000))

        // Sample disk usage at end-of-execution, before the report is sent,
        // so the persisted diagnostics reflect this job's actual footprint.
        // The defer will re-use these readings instead of walking again.
        disk.workdirPeakBytes = directorySizeBytes(at: paths.workDir)
        disk.freeMBAtEnd = freeSpaceMB(at: tempRoot)

        let collection = makeCollection(
            outcomes: outcomes,
            warnings: prepared.normalizationWarnings,
            job: job,
            startedAt: jobStartedAt,
            finishedAt: Date()
        )
        let diagnostics = makeExecutionDiagnostics(
            collection: collection,
            jobStartedAt: jobStartedAt,
            stageTimings: stageTimings,
            disk: disk
        )
        try await reportJobResult(
            job: job,
            collection: collection,
            diagnostics: diagnostics,
            matches: matches,
            stageTimings: &stageTimings
        )
    }

    // MARK: - Per-job setup helpers

    private func logJobAccepted(_ job: Job) {
        writeStructuredRunnerLog(
            event: "job_accepted",
            fields: [
                "runner_id": workerID,
                "submission_id": job.submissionID,
                "job_id": job.submissionID,
                "test_setup_id": job.testSetupID,
                "attempt_number": job.attemptNumber,
                "runner_active_jobs": activeJobs,
                "max_jobs": maxConcurrentJobs,
            ])
    }

    /// Heartbeat loop scoped to the lifetime of one job. We use a manual
    /// Task + defer-cancel rather than a `withTaskGroup` because the body
    /// of `process()` is straight-line code with many local bindings;
    /// wrapping it in a group closure would balloon nesting without changing
    /// behaviour.
    ///
    /// Cancellation flow: when the outer worker loop is cancelled, the
    /// current `await` in `process()` throws, control runs to the defer,
    /// we cancel this task explicitly, and `Task.sleep`'s `CancellationError`
    /// short-circuits the loop on its next wake.
    private func startHeartbeatLoop() -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    break  // cancellation: skip the final heartbeat
                }
                try? await self.sendHeartbeat()
            }
        }
    }
}
