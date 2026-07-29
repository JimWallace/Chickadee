// Worker/RunnerDaemon+JobProcessing.swift
//
// Job-processing extension for WorkerDaemon — the per-job pipeline
// (process → executeTestSuites → interpretOutput → makeCollection).
// Split from RunnerDaemon.swift for navigability.

import ArgumentParser
import Core
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
    let preferredStudentModule: String?
    let testSetupCacheHit: Bool
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
            // Fire-and-forget end-of-job heartbeat so the server's
            // last-seen timestamp advances even if this job took >30s.
            Task { try? await self.sendHeartbeat() }
        }

        let tempRoot = FileManager.default.temporaryDirectory
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
        let outcomes = try await executeTestSuites(
            manifest: prepared.manifest,
            testSetupDir: prepared.testSetupDir,
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
            startedAt: jobStartedAt
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
            stageTimings: &stageTimings
        )
    }

    // MARK: - Per-job setup helpers

    /// Best-effort workspace removal that leaves a structured breadcrumb on
    /// failure — a silently leaked workdir is a disk leak ops can only find
    /// from this log line. Quiet when the path is already gone.
    private func removeWorkspaceItem(at url: URL, label: String, job: Job) {
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

    /// Runs the workspace teardown that has to fire whether or not the job
    /// reached the happy path: lazily samples the disk readings the body
    /// skipped, removes the workdir, records the `cleanup` stage timing,
    /// and emits the two structured log events ops uses for capacity
    /// dashboards.
    private func finalizeJobWorkspace(
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

    private func makeExecutionDiagnostics(
        collection: TestOutcomeCollection,
        jobStartedAt: Date,
        stageTimings: JobStageTimings,
        disk: JobDiskReadings
    ) -> WorkerExecutionDiagnostics {
        WorkerExecutionDiagnostics(
            runnerID: workerID,
            startedAt: jobStartedAt,
            finishedAt: collection.timestamp,
            finalStatus: inferredCollectionStatus(collection).rawValue,
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

    // MARK: - Per-job phases

    /// Throws `insufficientDiskSpace` if the workspace partition is below
    /// the configured floor — early exit so the runner can decline the job
    /// before downloading anything.
    private func ensureSufficientDiskSpace(
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
    private func setupJobWorkspace(
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

    /// Downloads + unzips the submission and test setup, stages the
    /// submission into the test workspace, runs the optional `make` step,
    /// and installs the runtime helpers.  Returns a `JobPreparedWorkspace`
    /// that the caller hands to `executeTestSuites`.
    private func prepareJobWorkspace(
        job: Job,
        paths: JobWorkspacePaths,
        stageTimings: inout JobStageTimings
    ) async throws -> JobPreparedWorkspace {
        // Download submission and acquire the prepared test setup concurrently.
        // The test setup is served from the LRU cache: on a hit the cached
        // directory is copied into a fresh scratch location; on a miss it is
        // downloaded, unzipped, committed to cache, then copied.
        let submissionDownloadStartedAt = Date()
        async let submissionDownload: Void = download(url: job.submissionURL, to: paths.submissionZip)

        let testSetupAcquireStartedAt = Date()
        let cacheKey = testSetupCacheKey(for: job)
        let acquireResult = try await testSetupCache.acquire(testSetupID: cacheKey) {
            let stagingZip = paths.workDir.appendingPathComponent("testsetup.zip")
            let stagingDir = paths.workDir.appendingPathComponent("testsetup_staging", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            try await self.download(url: job.testSetupURL, to: stagingZip)
            try await extractZipArchive(zipPath: stagingZip.path, into: stagingDir)
            return stagingDir
        }
        let testSetupDir = acquireResult.directory
        stageTimings.record(
            "test_setup_acquire",
            milliseconds: Int(Date().timeIntervalSince(testSetupAcquireStartedAt) * 1000)
        )
        stageTimings.testSetupCacheHit = acquireResult.didHit

        // From here the scratch copy is caller-owned, but `process(_:)` only
        // registers its cleanup `defer` after we return — so any throw in the
        // remaining prepare stages (submission download, staging, the routine
        // invalid-upload normalization failure, `make`, helper writes) must
        // remove the directory itself before rethrowing, or every failed job
        // leaks a fully-prepared test-setup dir in /tmp (#1106; disk-fill has
        // taken prod down once already).
        do {
            try await submissionDownload
            stageTimings.record(
                "submission_download",
                milliseconds: Int(Date().timeIntervalSince(submissionDownloadStartedAt) * 1000)
            )

            let manifest = job.manifest

            try await stageSubmissionIntoWorkspace(
                job: job,
                paths: paths,
                stageTimings: &stageTimings
            )

            try removeStarterNotebookIfPresent(
                manifest: manifest,
                testSetupDir: testSetupDir,
                submissionFilename: job.submissionFilename,
                stageTimings: &stageTimings
            )

            let (normalizationWarnings, preferredStudentModule) = try normalizeSubmission(
                job: job,
                manifest: manifest,
                paths: paths,
                testSetupDir: testSetupDir,
                stageTimings: &stageTimings
            )

            // Optional make step (bounded — see runMake, #1107). Timed
            // inline: `measure`'s closure can't hop to this actor's
            // isolation, and the failure path doesn't record a timing
            // (matching the old measureSync behaviour).
            if let makefile = manifest.makefile {
                let makeStartedAt = Date()
                try await runMake(in: testSetupDir, target: makefile.target)
                stageTimings.record(
                    "make_step", milliseconds: Int(Date().timeIntervalSince(makeStartedAt) * 1000))
            }

            // Materialize per-student personalization inputs (issue #461) into the
            // grading workspace as `_ck_inputs.py` (Python) or `_ck_inputs.R` (R),
            // so generated pattern-family scripts / hand-authored tests that
            // reference per-student args / expected can load them by path. Each
            // value is already a source literal in the job's language (`repr` /
            // `deparse`) resolved server-side; `AssignmentLanguage.renderInputsFile`
            // owns the exact bytes (the Python form is byte-for-byte the historical
            // writer, so existing Python jobs are unchanged). The filename is
            // reserved (excluded from student-module candidates in the runtimes), so
            // it can't be mistaken for the submission. Language is nil on payloads
            // from an older server → `.python`, preserving legacy behaviour.
            if let inputs = job.personalizedInputs, !inputs.isEmpty {
                let language = job.language ?? .python
                let source = language.renderInputsFile(inputs)
                // A failed write here would make every personalized test error with
                // a confusing missing-file traceback that looks like a student
                // mistake — and persist it as their grade. Throw instead so the job
                // is reported as buildStatus:failed and stays retestable.
                try source.write(
                    to: testSetupDir.appendingPathComponent(language.inputsFileName),
                    atomically: true, encoding: .utf8)
            }

            // Materialize per-student dataset slices (Phase 1 datasets — see
            // docs/datasets.md) into the grading workspace, overwriting the source
            // pool copied from the cached test-setup so student scripts read only
            // their slice. Same delivery shape as `_ck_inputs.py`: the server
            // resolved the bytes (`DatasetResolver` over the seed); we only write
            // them. A failed write would silently grade the student against the
            // wrong (pool) data, so throw — the job is reported buildStatus:failed
            // and stays retestable, matching the `_ck_inputs.py` rationale above.
            if let files = job.personalizedFiles, !files.isEmpty {
                for name in files.keys.sorted() {
                    guard let content = files[name] else { continue }
                    // A personalized file replaces a bundled support file by bare
                    // name; a path-carrying key must never write outside the
                    // grading workspace (#1104). Throw rather than skip — same
                    // rationale as the write-failure case above.
                    guard FilenameSafety.bareFilename(name) != nil else {
                        throw WorkerDaemonError.unsafePersonalizedFilename(name)
                    }
                    try content.write(
                        to: testSetupDir.appendingPathComponent(name),
                        atomically: true, encoding: .utf8)
                }
            }

            // Install shared Python test runtime helpers for every run.
            try stageTimings.measureSync("runtime_helper_setup") {
                try writePythonRuntimeHelpers(in: testSetupDir)
                try writeStudentModuleHint(in: testSetupDir, preferredFilename: preferredStudentModule)
                try writeRRuntimeHelper(in: testSetupDir)
            }

            return JobPreparedWorkspace(
                testSetupDir: testSetupDir,
                manifest: manifest,
                normalizationWarnings: normalizationWarnings,
                preferredStudentModule: preferredStudentModule,
                testSetupCacheHit: acquireResult.didHit
            )
        } catch {
            removeWorkspaceItem(at: testSetupDir, label: "test_setup_dir", job: job)
            throw error
        }
    }

    /// Stage the submission independently from the grading workspace so the
    /// worker can normalize it without mutating the raw artifact.
    private func stageSubmissionIntoWorkspace(
        job: Job,
        paths: JobWorkspacePaths,
        stageTimings: inout JobStageTimings
    ) async throws {
        try await stageTimings.measure("submission_unpack") {
            if let filename = job.submissionFilename {
                let dest = stagedSubmissionDestination(
                    submissionDirectory: paths.submissionDir,
                    submittedFilename: filename
                )
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: paths.submissionZip, to: dest)
            } else {
                try await extractZipArchive(
                    zipPath: paths.submissionZip.path,
                    into: paths.submissionDir
                )
            }
        }
    }

    /// Remove the starter notebook template from the test directory so
    /// grading scripts that scan for *.ipynb don't see both the template
    /// and the student/canonical submission.  Older manifests lack
    /// starterNotebook — fall back to "assignment.ipynb" since that is
    /// the conventional name used by every existing assignment.
    private func removeStarterNotebookIfPresent(
        manifest: TestProperties,
        testSetupDir: URL,
        submissionFilename: String?,
        stageTimings: inout JobStageTimings
    ) throws {
        try stageTimings.measureSync("starter_cleanup") {
            let starterName = manifest.starterNotebook ?? "assignment.ipynb"
            let starterPath = testSetupDir.appendingPathComponent(starterName)
            if FileManager.default.fileExists(atPath: starterPath.path),
                submissionFilename != starterName
            {
                try FileManager.default.removeItem(at: starterPath)
            }
        }
    }

    private func normalizeSubmission(
        job: Job,
        manifest: TestProperties,
        paths: JobWorkspacePaths,
        testSetupDir: URL,
        stageTimings: inout JobStageTimings
    ) throws -> ([String], String?) {
        try stageTimings.measureSync("submission_prepare") {
            if shouldNormalizePythonSubmission(
                manifest: manifest,
                submissionFilename: job.submissionFilename,
                submissionDirectory: paths.submissionDir
            ) {
                let normalizer = SubmissionNormalizer()
                let normalization = try normalizer.normalizePythonSubmission(
                    manifest: manifest,
                    submissionDirectory: paths.submissionDir,
                    workspaceDirectory: testSetupDir,
                    submissionFilename: job.submissionFilename
                )
                return (normalization.warnings, normalization.preferredStudentModule)
            } else {
                try mergeDirectoryContents(from: paths.submissionDir, into: testSetupDir)
                // A pure-R suite extracts every notebook to `.R` regardless of the
                // submission's kernelspec (the in-browser editor can rewrite it) —
                // so the student-module hint has to name the `.R` file too, or it
                // points at a path that was never written.
                let targetsR = manifestTargetsRSubmission(manifest)
                try extractNotebooksToCode(
                    in: testSetupDir,
                    forcedLanguage: targetsR ? .r : nil)
                return (
                    [],
                    legacyPreferredStudentModuleFilename(
                        submissionFilename: job.submissionFilename,
                        language: targetsR ? .r : .python)
                )
            }
        }
    }

    private func reportJobResult(
        job: Job,
        collection: TestOutcomeCollection,
        diagnostics: WorkerExecutionDiagnostics,
        stageTimings: inout JobStageTimings
    ) async throws {
        do {
            let resultReportStartedAt = Date()
            try await reporter.report(WorkerExecutionReport(collection: collection, diagnostics: diagnostics))
            stageTimings.record(
                "result_report",
                milliseconds: Int(Date().timeIntervalSince(resultReportStartedAt) * 1000)
            )
            writeStructuredRunnerLog(
                event: "result_submission_succeeded",
                fields: [
                    "runner_id": workerID,
                    "submission_id": job.submissionID,
                    "status": inferredCollectionStatus(collection).rawValue,
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

    // MARK: - Per-job tear-down logging

    private func emitJobStageTimingsLog(
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
    private func emitJobDiskUsageLog(
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

    // MARK: - Test execution

    /// Projects the manifest entries to RunnerCore's runtime `SuiteItem` view
    /// and drives the shared `executeSuites` loop. The dependency pass-gate,
    /// skip messages, missing-script handling, and outcome shaping all live in
    /// RunnerCore now — shared byte-for-byte with the browser runner. The worker
    /// supplies its substrate (`NativeScriptExecutor`) and its structured
    /// logging via the event sink.
    private func executeTestSuites(
        manifest: TestProperties,
        testSetupDir: URL,
        job: Job
    ) async throws -> [TestOutcome] {
        // Phase 1 of issue #461 — surface the per-(student, assignment) seed to
        // the grading subprocess. Nil/empty seed means non-personalized job;
        // leaving the env var unset preserves legacy behaviour.
        var scriptEnv: [String: String] = [:]
        if let seed = job.assignmentSeed, !seed.isEmpty {
            scriptEnv["CHICKADEE_ASSIGNMENT_SEED"] = seed
        }

        // Per-student file materialization (`_ck_inputs.py` + dataset slices)
        // happens in `prepareJobWorkspace` — workspace prep, not execution —
        // so `test_execution` stage timing measures only the suite run and the
        // prepare-phase scratch cleanup (#1106) covers materialization throws.

        // Per-test time-limit overrides resolved in the executor (the shared
        // `executeSuites` loop still receives the assignment default below as
        // the fallback). Only entries carrying an explicit positive override
        // are mapped; everything else inherits `manifest.timeLimitSeconds`.
        var timeLimitOverrides: [String: Int] = [:]
        for entry in manifest.testSuites {
            if let limit = entry.timeLimitSeconds, limit > 0 {
                timeLimitOverrides[entry.script] = limit
            }
        }
        let executor = NativeScriptExecutor(
            runner: runner, workDir: testSetupDir, env: scriptEnv, overrides: timeLimitOverrides)
        let items = manifest.testSuites.map { entry in
            SuiteItem(
                script: entry.script,
                tier: entry.tier,
                displayName: entry.name,
                dependsOn: entry.dependsOn,
                points: entry.points
            )
        }

        // Capture only value types so the @Sendable event sink can run on the
        // loop's (nonisolated) executor without touching actor state.
        let runnerID = workerID
        let submissionID = job.submissionID
        return await executeSuites(
            items,
            timeLimitSeconds: manifest.timeLimitSeconds,
            attemptNumber: job.attemptNumber,
            executor: executor,
            onEvent: { event in
                logSuiteRunEvent(event, runnerID: runnerID, submissionID: submissionID)
            }
        )
    }

    // MARK: - Collection assembly

    private func makeCollection(
        outcomes: [TestOutcome],
        warnings: [String],
        job: Job,
        startedAt: Date
    ) -> TestOutcomeCollection {
        // One pass over the outcomes instead of six (4 × filter().count +
        // 2 × reduce) — the codebase's own stated antipattern.
        var passCount = 0
        var failCount = 0
        var errorCount = 0
        var timeoutCount = 0
        var totalMs = 0
        var totalPoints = 0
        // Weighted, partial-credit-aware: points × score per outcome (a script
        // with no footer `score` scores 1 on a pass / 0 otherwise, so this equals
        // the old "sum points for passing tests" for non-partial-credit suites).
        var earnedPoints = 0.0
        for outcome in outcomes {
            switch outcome.status {
            case .pass: passCount += 1
            case .fail: failCount += 1
            case .error: errorCount += 1
            case .timeout: timeoutCount += 1
            }
            totalMs += outcome.executionTimeMs
            totalPoints += outcome.points
            earnedPoints += Double(outcome.points) * outcome.score
        }

        let buildStatus: BuildStatus = outcomes.isEmpty ? .failed : .passed

        return TestOutcomeCollection(
            submissionID: job.submissionID,
            testSetupID: job.testSetupID,
            attemptNumber: job.attemptNumber,
            buildStatus: buildStatus,
            compilerOutput: nil,
            outcomes: outcomes,
            totalTests: outcomes.count,
            passCount: passCount,
            failCount: failCount,
            errorCount: errorCount,
            timeoutCount: timeoutCount,
            executionTimeMs: totalMs,
            totalPoints: totalPoints,
            earnedPoints: earnedPoints,
            warnings: warnings,
            jobStartedAt: startedAt,
            runnerVersion: ChickadeeVersion.current,
            timestamp: Date()
        )
    }

}

// MARK: - Script output interpretation (pure contract)

// `InterpretedScriptResult` and `interpretScriptOutput(_:)` now live in
// RunnerCore (the wasm-safe leaf shared with the browser runner), as does the
// suite-execution loop itself (`executeSuites` + the `ScriptExecutor` protocol).
// Reached here via `import Core` (which re-exports RunnerCore).

// MARK: - Suite-run event logging

/// Maps RunnerCore's `SuiteRunEvent`s onto the worker's structured log stream,
/// preserving the exact event names and fields the loop used to emit inline
/// (`local_execution_error` / `test_execution_start` / `test_execution_end` /
/// `timeout`). A free function — not an actor method — so the shared
/// `executeSuites` loop can invoke it from its own (nonisolated) executor; it
/// captures only value types.
private func logSuiteRunEvent(_ event: SuiteRunEvent, runnerID: String, submissionID: String) {
    switch event {
    case .missingScript(let script):
        writeStructuredRunnerLog(
            event: "local_execution_error",
            fields: [
                "runner_id": runnerID,
                "submission_id": submissionID,
                "test_id": script,
                "error_type": "missing_script",
                "error_message_summary": script,
            ])
    case .willRun(let script):
        writeStructuredRunnerLog(
            event: "test_execution_start",
            fields: [
                "runner_id": runnerID,
                "submission_id": submissionID,
                "test_id": script,
            ])
    case .didFinish(_, let outcome, let timedOut):
        writeStructuredRunnerLog(
            event: timedOut ? "timeout" : "test_execution_end",
            fields: [
                "runner_id": runnerID,
                "submission_id": submissionID,
                "test_id": normalizedTestID(for: outcome),
                "status": outcome.status.rawValue,
                "execution_ms": outcome.executionTimeMs,
            ])
    }
}

/// Combines `testClass` + `testName` into the dotted ID used in log events.
/// Free function so both the `WorkerDaemon` actor and the suite-run event sink
/// can call it without crossing an isolation boundary.
func normalizedTestID(for outcome: TestOutcome) -> String {
    let classPart = outcome.testClass?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return classPart.isEmpty ? outcome.testName : "\(classPart).\(outcome.testName)"
}
