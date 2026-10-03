// Worker/JobWorkspace.swift
//
// The per-job workspace: the paths a job runs in, what the prepare phase
// hands to the later phases, and the disk readings taken across the job.
// The setup and teardown of that workspace live here too. Split from
// RunnerDaemon+JobProcessing.swift (#1799).

import Core
import Foundation

/// URLs derived from the job's per-run workdir.  Built once at the top of
/// `process(_:)` and passed through every phase helper so callers don't have
/// to thread half a dozen `URL`s individually.
struct JobWorkspacePaths {
    let tempRoot: URL
    let workDir: URL
    let submissionZip: URL
    let submissionDir: URL
}

/// Output of the prepare phase (submission staged into the workspace,
/// normalisation run, runtime helpers installed).  Carries everything the
/// later phases need to assemble the result collection.
struct JobPreparedWorkspace {
    let testSetupDir: URL
    let manifest: TestProperties
    let normalizationWarnings: [String]
    /// The staged opponent for a match job (`stageOpponentWorkspace`); nil
    /// for an ordinary run.
    let opponentDir: URL?
    /// The staged opponents of a matrix job, in `Job.opponents` order; empty
    /// for every other job.
    let opponentDirs: [URL]
}

/// Disk-space samples taken across the lifetime of a job.  The "at start"
/// reading is captured up-front; the "at end" reading is filled in either
/// just before the report is sent (happy path) or by the cleanup defer
/// (error path), so it represents the worst-case free-disk reading.
struct JobDiskReadings {
    var freeMBAtStart: Int?
    var freeMBAtEnd: Int?
    var workdirPeakBytes: Int?
}

/// Outcome of the two concurrent prepare-phase artifact fetches.  Both legs
/// are `Result`s rather than `throws` on purpose — see `fetchJobArtifacts`.
struct JobArtifactFetch {
    let submission: Result<Void, Error>
    let testSetup: Result<TestSetupCache.AcquireResult, Error>
    let testSetupAcquireMilliseconds: Int
}

extension WorkerDaemon {

    // MARK: - Setup

    /// Best-effort workspace removal that leaves a structured breadcrumb on
    /// failure — a silently leaked workdir is a disk leak ops can only find
    /// from this log line. Quiet when the path is already gone.
    func removeWorkspaceItem(at url: URL, label: String, job: Job) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            writeStructuredRunnerLog(
                event: "workspace_cleanup_failed",
                fields: [
                    "runner_id": workerID,
                    "submission_id": job.submissionID,
                    "label": label,
                    "path": url.path,
                    "error": String(describing: error),
                ])
        }
    }

    /// Throws `insufficientDiskSpace` if the workspace partition is below
    /// the configured floor — early exit so the runner can decline the job
    /// before downloading anything.
    func ensureSufficientDiskSpace(
        tempRoot: URL,
        freeDiskMBAtStart: Int?,
        job: Job
    ) throws {
        guard config.minFreeDiskMB > 0,
            let freeMB = freeDiskMBAtStart,
            freeMB < config.minFreeDiskMB
        else { return }

        writeStructuredRunnerLog(
            event: "insufficient_disk_space",
            fields: [
                "runner_id": workerID,
                "submission_id": job.submissionID,
                "path": tempRoot.path,
                "free_mb": freeMB,
                "required_mb": config.minFreeDiskMB,
            ])
        throw WorkerDaemonError.insufficientDiskSpace(
            path: tempRoot.path,
            freeMB: freeMB,
            requiredMB: config.minFreeDiskMB
        )
    }

    /// Creates the per-job workspace (workdir + submission subdir) and
    /// records the `workdir_setup` / `submission_dir_setup` stage timings.
    func setupJobWorkspace(
        tempRoot: URL,
        job: Job,
        stageTimings: inout JobStageTimings
    ) throws -> JobWorkspacePaths {
        let workDir =
            tempRoot
            .appendingPathComponent("chickadee_\(job.submissionID)_\(UUID().uuidString)", isDirectory: true)
        let workDirSetupStartedAt = Date()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        stageTimings.record(
            "workdir_setup",
            milliseconds: Int(Date().timeIntervalSince(workDirSetupStartedAt) * 1000)
        )

        let submissionZip = workDir.appendingPathComponent("submission.zip")
        let submissionDir = workDir.appendingPathComponent("submission", isDirectory: true)
        try stageTimings.measureSync("submission_dir_setup") {
            try FileManager.default.createDirectory(at: submissionDir, withIntermediateDirectories: true)
        }
        return JobWorkspacePaths(
            tempRoot: tempRoot,
            workDir: workDir,
            submissionZip: submissionZip,
            submissionDir: submissionDir
        )
    }

    // MARK: - Teardown

    /// Runs the workspace teardown that has to fire whether or not the job
    /// reached the happy path: lazily samples the disk readings the body
    /// skipped, removes the workdir, records the `cleanup` stage timing,
    /// and emits the two structured log events ops uses for capacity
    /// dashboards.
    func finalizeJobWorkspace(
        job: Job,
        paths: JobWorkspacePaths,
        tempRoot: URL,
        jobStartedAt: Date,
        stageTimings: inout JobStageTimings,
        disk: inout JobDiskReadings
    ) {
        // If the happy path already measured these (right before the
        // report), don't double-walk the directory.
        if disk.workdirPeakBytes == nil {
            disk.workdirPeakBytes = directorySizeBytes(at: paths.workDir)
        }
        if disk.freeMBAtEnd == nil {
            disk.freeMBAtEnd = freeSpaceMB(at: tempRoot)
        }

        let cleanupStartedAt = Date()
        removeWorkspaceItem(at: paths.workDir, label: "work_dir", job: job)
        stageTimings.record("cleanup", milliseconds: Int(Date().timeIntervalSince(cleanupStartedAt) * 1000))

        let freeDiskMBPostCleanup = freeSpaceMB(at: tempRoot)
        let totalWallClockMs = Int(Date().timeIntervalSince(jobStartedAt) * 1000)
        emitJobStageTimingsLog(
            stageTimings: stageTimings,
            job: job,
            totalWallClockMs: totalWallClockMs
        )
        emitJobDiskUsageLog(
            tempRoot: tempRoot,
            job: job,
            disk: disk,
            freeDiskMBPostCleanup: freeDiskMBPostCleanup
        )
    }

    func emitJobStageTimingsLog(
        stageTimings: JobStageTimings,
        job: Job,
        totalWallClockMs: Int
    ) {
        var fields: [String: Any] = [
            "runner_id": workerID,
            "submission_id": job.submissionID,
            "job_id": job.submissionID,
            "total_wall_clock_ms": totalWallClockMs,
        ]
        for (key, value) in stageTimings.fields() {
            fields[key] = value
        }
        writeStructuredRunnerLog(event: "job_stage_timings", fields: fields)
    }

    /// Emit a dedicated disk-usage event so ops can answer "are we
    /// close to the floor?" without having to join across log events.
    func emitJobDiskUsageLog(
        tempRoot: URL,
        job: Job,
        disk: JobDiskReadings,
        freeDiskMBPostCleanup: Int?
    ) {
        var diskFields: [String: Any] = [
            "runner_id": workerID,
            "submission_id": job.submissionID,
            "job_id": job.submissionID,
            "path": tempRoot.path,
            "min_free_disk_mb": config.minFreeDiskMB,
        ]
        if let v = disk.freeMBAtStart { diskFields["free_disk_mb_at_start"] = v }
        if let v = disk.freeMBAtEnd { diskFields["free_disk_mb_at_end"] = v }
        if let v = freeDiskMBPostCleanup { diskFields["free_disk_mb_post_cleanup"] = v }
        if let v = disk.workdirPeakBytes { diskFields["workdir_peak_bytes"] = v }
        writeStructuredRunnerLog(event: "job_disk_usage", fields: diskFields)
    }
}
