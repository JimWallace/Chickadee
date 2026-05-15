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

extension WorkerDaemon {

    // MARK: - Job processing

    func process(_ job: Job) async throws {
        activeJobs += 1
        let jobStartedAt = Date()
        defer { activeJobs = max(0, activeJobs - 1) }
        var stageTimings = JobStageTimings()

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
        try? await sendHeartbeat()

        // Heartbeat loop scoped to the lifetime of this job. We use a manual
        // Task + defer-cancel rather than a `withTaskGroup` because the
        // remainder of `process()` is straight-line code with many local
        // bindings; wrapping it in a group closure would balloon nesting
        // without changing behaviour.
        //
        // Cancellation flow: when the outer worker loop is cancelled, the
        // current `await` in `process()` throws, control runs to the defer,
        // we cancel the heartbeat task explicitly, and `Task.sleep`'s
        // `CancellationError` short-circuits the loop on its next wake.
        let heartbeatTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    break  // cancellation: skip the final heartbeat
                }
                try? await self.sendHeartbeat()
            }
        }
        defer {
            heartbeatTask.cancel()
            // Fire-and-forget end-of-job heartbeat so the server's
            // last-seen timestamp advances even if this job took >30s.
            Task { try? await self.sendHeartbeat() }
        }

        let tempRoot = FileManager.default.temporaryDirectory
        let freeDiskMBAtStart = freeSpaceMB(at: tempRoot)
        if config.minFreeDiskMB > 0,
            let freeMB = freeDiskMBAtStart,
            freeMB < config.minFreeDiskMB
        {
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

        let workDir =
            tempRoot
            .appendingPathComponent("chickadee_\(job.submissionID)_\(UUID().uuidString)", isDirectory: true)
        let workDirSetupStartedAt = Date()
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        stageTimings.record("workdir_setup", milliseconds: Int(Date().timeIntervalSince(workDirSetupStartedAt) * 1000))

        // Mutable so the body can populate them before building the
        // diagnostics report (and so the defer can emit a structured event
        // even on error paths where the body didn't reach the report).
        // `freeDiskMBAtEnd` is sampled just before cleanup, so it represents
        // the worst-case free-disk reading for this job.
        var workdirPeakBytes: Int? = nil
        var freeDiskMBAtEnd: Int? = nil
        defer {
            // If the happy path already measured these (right before the
            // report), don't double-walk the directory.
            if workdirPeakBytes == nil {
                workdirPeakBytes = directorySizeBytes(at: workDir)
            }
            if freeDiskMBAtEnd == nil {
                freeDiskMBAtEnd = freeSpaceMB(at: tempRoot)
            }

            let cleanupStartedAt = Date()
            try? FileManager.default.removeItem(at: workDir)
            stageTimings.record("cleanup", milliseconds: Int(Date().timeIntervalSince(cleanupStartedAt) * 1000))

            let freeDiskMBPostCleanup = freeSpaceMB(at: tempRoot)
            let totalWallClockMs = Int(Date().timeIntervalSince(jobStartedAt) * 1000)
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

            // Emit a dedicated disk-usage event so ops can answer "are we
            // close to the floor?" without having to join across log events.
            var diskFields: [String: Any] = [
                "runner_id": workerID,
                "submission_id": job.submissionID,
                "job_id": job.submissionID,
                "path": tempRoot.path,
                "min_free_disk_mb": config.minFreeDiskMB,
            ]
            if let v = freeDiskMBAtStart { diskFields["free_disk_mb_at_start"] = v }
            if let v = freeDiskMBAtEnd { diskFields["free_disk_mb_at_end"] = v }
            if let v = freeDiskMBPostCleanup { diskFields["free_disk_mb_post_cleanup"] = v }
            if let v = workdirPeakBytes { diskFields["workdir_peak_bytes"] = v }
            writeStructuredRunnerLog(event: "job_disk_usage", fields: diskFields)
        }

        // Download submission and acquire the prepared test setup concurrently.
        // The test setup is served from the LRU cache: on a hit the cached
        // directory is copied into a fresh scratch location; on a miss it is
        // downloaded, unzipped, committed to cache, then copied.
        let submissionZip = workDir.appendingPathComponent("submission.zip")
        let submissionDir = workDir.appendingPathComponent("submission", isDirectory: true)
        try stageTimings.measureSync("submission_dir_setup") {
            try FileManager.default.createDirectory(at: submissionDir, withIntermediateDirectories: true)
        }

        let submissionDownloadStartedAt = Date()
        async let submissionDownload: Void = download(url: job.submissionURL, to: submissionZip)

        let testSetupAcquireStartedAt = Date()
        let testSetupCacheKey = testSetupCacheKey(for: job)
        let acquireResult = try await testSetupCache.acquire(testSetupID: testSetupCacheKey) {
            let stagingZip = workDir.appendingPathComponent("testsetup.zip")
            let stagingDir = workDir.appendingPathComponent("testsetup_staging", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            try await self.download(url: job.testSetupURL, to: stagingZip)
            try self.unzip(stagingZip, to: stagingDir)
            return stagingDir
        }
        let testSetupDir = acquireResult.directory
        stageTimings.record(
            "test_setup_acquire", milliseconds: Int(Date().timeIntervalSince(testSetupAcquireStartedAt) * 1000))
        stageTimings.testSetupCacheHit = acquireResult.didHit
        defer { try? FileManager.default.removeItem(at: testSetupDir) }

        try await submissionDownload
        stageTimings.record(
            "submission_download", milliseconds: Int(Date().timeIntervalSince(submissionDownloadStartedAt) * 1000))

        let manifest = job.manifest

        // Stage the submission independently from the grading workspace so the
        // worker can normalize it without mutating the raw artifact.
        try stageTimings.measureSync("submission_unpack") {
            if let filename = job.submissionFilename {
                let dest = stagedSubmissionDestination(
                    submissionDirectory: submissionDir,
                    submittedFilename: filename
                )
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: submissionZip, to: dest)
            } else {
                try unzip(submissionZip, to: submissionDir)
            }
        }

        // Remove the starter notebook template from the test directory so
        // grading scripts that scan for *.ipynb don't see both the template
        // and the student/canonical submission.  Older manifests lack
        // starterNotebook — fall back to "assignment.ipynb" since that is
        // the conventional name used by every existing assignment.
        try stageTimings.measureSync("starter_cleanup") {
            let starterName = manifest.starterNotebook ?? "assignment.ipynb"
            do {
                let starterPath = testSetupDir.appendingPathComponent(starterName)
                if FileManager.default.fileExists(atPath: starterPath.path),
                    job.submissionFilename != starterName
                {
                    try FileManager.default.removeItem(at: starterPath)
                }
            }
        }

        let normalizationWarnings: [String]
        let preferredStudentModule: String?
        (normalizationWarnings, preferredStudentModule) = try stageTimings.measureSync("submission_prepare") {
            if shouldNormalizePythonSubmission(
                manifest: manifest,
                submissionFilename: job.submissionFilename,
                submissionDirectory: submissionDir
            ) {
                let normalizer = SubmissionNormalizer()
                let normalization = try normalizer.normalizePythonSubmission(
                    manifest: manifest,
                    submissionDirectory: submissionDir,
                    workspaceDirectory: testSetupDir,
                    submissionFilename: job.submissionFilename
                )
                return (normalization.warnings, normalization.preferredStudentModule)
            } else {
                try mergeDirectoryContents(from: submissionDir, into: testSetupDir)
                try extractNotebooksToCode(in: testSetupDir)
                return ([], legacyPreferredStudentModuleFilename(submissionFilename: job.submissionFilename))
            }
        }

        // Optional make step.
        try stageTimings.measureSync("make_step") {
            if let makefile = manifest.makefile {
                try runMake(in: testSetupDir, target: makefile.target)
            }
        }

        // Install shared Python test runtime helpers for every run.
        try stageTimings.measureSync("runtime_helper_setup") {
            try writePythonRuntimeHelpers(in: testSetupDir)
            try writeStudentModuleHint(in: testSetupDir, preferredFilename: preferredStudentModule)
            try writeRRuntimeHelper(in: testSetupDir)
        }

        let testExecutionStartedAt = Date()
        let outcomes = await executeTestSuites(
            manifest: manifest,
            testSetupDir: testSetupDir,
            job: job
        )
        stageTimings.record(
            "test_execution", milliseconds: Int(Date().timeIntervalSince(testExecutionStartedAt) * 1000))

        // Sample disk usage at end-of-execution, before the report is sent,
        // so the persisted diagnostics reflect this job's actual footprint.
        // The defer will re-use these readings instead of walking again.
        workdirPeakBytes = directorySizeBytes(at: workDir)
        freeDiskMBAtEnd = freeSpaceMB(at: tempRoot)

        let collection = makeCollection(
            outcomes: outcomes,
            warnings: normalizationWarnings,
            job: job,
            startedAt: jobStartedAt
        )
        let diagnostics = WorkerExecutionDiagnostics(
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
            freeDiskMBAtStart: freeDiskMBAtStart,
            freeDiskMBAtEnd: freeDiskMBAtEnd,
            workdirPeakBytes: workdirPeakBytes
        )
        do {
            let resultReportStartedAt = Date()
            try await reporter.report(WorkerExecutionReport(collection: collection, diagnostics: diagnostics))
            stageTimings.record(
                "result_report", milliseconds: Int(Date().timeIntervalSince(resultReportStartedAt) * 1000))
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

    // MARK: - Test execution

    /// Walks `manifest.testSuites` in order, honouring the `dependsOn`
    /// pass-gate: a test whose prerequisite hasn't passed is auto-failed
    /// with a `Skipped:` short result instead of executed. Missing script
    /// files are logged and skipped entirely (no outcome emitted, matching
    /// the pre-extraction behaviour).
    private func executeTestSuites(
        manifest: TestProperties,
        testSetupDir: URL,
        job: Job
    ) async -> [TestOutcome] {
        var outcomes: [TestOutcome] = []
        var passedScripts: Set<String> = []

        for entry in manifest.testSuites {
            if let blockedBy = entry.dependsOn.first(where: { !passedScripts.contains($0) }),
                !entry.dependsOn.isEmpty
            {
                let baseName = (entry.script as NSString).deletingPathExtension
                let displayName = entry.name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                outcomes.append(
                    TestOutcome(
                        testName: displayName ?? (baseName.isEmpty ? entry.script : baseName),
                        testClass: nil,
                        tier: entry.tier,
                        status: .fail,
                        shortResult: "Skipped: prerequisite '\(blockedBy)' did not pass",
                        longResult: nil,
                        executionTimeMs: 0,
                        memoryUsageBytes: nil,
                        attemptNumber: job.attemptNumber,
                        isFirstPassSuccess: false
                    ))
                continue
            }

            let scriptURL = testSetupDir.appendingPathComponent(entry.script)
            guard FileManager.default.fileExists(atPath: scriptURL.path) else {
                writeStructuredRunnerLog(
                    event: "local_execution_error",
                    fields: [
                        "runner_id": workerID,
                        "submission_id": job.submissionID,
                        "test_id": entry.script,
                        "error_type": "missing_script",
                        "error_message_summary": entry.script,
                    ])
                continue
            }

            writeStructuredRunnerLog(
                event: "test_execution_start",
                fields: [
                    "runner_id": workerID,
                    "submission_id": job.submissionID,
                    "test_id": entry.script,
                ])

            // Phase 1 of issue #461 — surface the per-(student, assignment)
            // seed to the grading subprocess. Nil seed means non-personalized
            // job; leaving the env var unset preserves legacy behaviour.
            var scriptEnv: [String: String] = [:]
            if let seed = job.assignmentSeed, !seed.isEmpty {
                scriptEnv["CHICKADEE_ASSIGNMENT_SEED"] = seed
            }
            let output = await runner.run(
                script: scriptURL,
                workDir: testSetupDir,
                timeLimitSeconds: manifest.timeLimitSeconds,
                env: scriptEnv
            )

            let isFirstAttempt = job.attemptNumber == 1
            let outcome = interpretOutput(
                output, entry: entry, attemptNumber: job.attemptNumber, isFirstAttempt: isFirstAttempt)
            outcomes.append(outcome)
            writeStructuredRunnerLog(
                event: output.timedOut ? "timeout" : "test_execution_end",
                fields: [
                    "runner_id": workerID,
                    "submission_id": job.submissionID,
                    "test_id": normalizedTestID(for: outcome),
                    "status": outcome.status.rawValue,
                    "execution_ms": outcome.executionTimeMs,
                ])
            if outcome.status == .pass {
                passedScripts.insert(entry.script)
            }
        }

        return outcomes
    }

    // MARK: - Script output interpretation

    private func interpretOutput(
        _ output: ScriptOutput,
        entry: TestSuiteEntry,
        attemptNumber: Int,
        isFirstAttempt: Bool
    ) -> TestOutcome {
        let status: TestStatus
        if output.timedOut {
            status = .timeout
        } else {
            switch output.exitCode {
            case 0: status = .pass
            case 1: status = .fail
            case 3: status = .fail  // chickadee.py (Marmoset) uses exit 3 for "failed"
            default: status = .error
            }
        }

        // Parse the last non-empty stdout line as optional JSON for score/shortResult.
        let lastLine = output.stdout
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })

        var shortResult: String

        if let line = lastLine,
            let data = line.data(using: .utf8),
            let json = try? JSONDecoder().decode(ScriptResultJSON.self, from: data)
        {
            shortResult = json.shortResult ?? status.defaultShortResult
            // json.score reserved for Phase 5 gamification
        } else if let line = lastLine {
            shortResult = line
        } else {
            shortResult = status.defaultShortResult
        }

        let stderrText = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip the JSON footer line from stdout before displaying to students.
        // The footer is the last non-empty line; if it parsed as JSON above we
        // remove it so only human-readable output appears in longResult.
        let strippedStdout: String = {
            guard let line = lastLine,
                let data = line.data(using: .utf8),
                (try? JSONDecoder().decode(ScriptResultJSON.self, from: data)) != nil
            else { return output.stdout }
            var lines = output.stdout.components(separatedBy: "\n")
            if let lastIdx = lines.indices.last(where: { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }) {
                lines.remove(at: lastIdx)
            }
            return lines.joined(separator: "\n")
        }()
        let stdoutText = strippedStdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let longResult: String? = {
            var sections: [String] = []
            if !stdoutText.isEmpty { sections.append("stdout:\n\(stdoutText)") }
            if !stderrText.isEmpty { sections.append("stderr:\n\(stderrText)") }
            return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
        }()
        let baseName = (entry.script as NSString).deletingPathExtension
        let displayName = entry.name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }

        return TestOutcome(
            testName: displayName ?? (baseName.isEmpty ? entry.script : baseName),
            testClass: nil,
            tier: entry.tier,
            status: status,
            shortResult: shortResult,
            longResult: longResult,
            points: entry.points,
            executionTimeMs: output.executionTimeMs,
            memoryUsageBytes: nil,
            attemptNumber: attemptNumber,
            isFirstPassSuccess: isFirstAttempt && status == .pass
        )
    }

    // MARK: - Collection assembly

    private func makeCollection(
        outcomes: [TestOutcome],
        warnings: [String],
        job: Job,
        startedAt: Date
    ) -> TestOutcomeCollection {
        let passCount = outcomes.filter { $0.status == .pass }.count
        let failCount = outcomes.filter { $0.status == .fail }.count
        let errorCount = outcomes.filter { $0.status == .error }.count
        let timeoutCount = outcomes.filter { $0.status == .timeout }.count
        let totalMs = outcomes.reduce(0) { $0 + $1.executionTimeMs }
        let totalPoints = outcomes.reduce(0) { $0 + $1.points }
        let earnedPoints = outcomes.filter { $0.status == .pass }.reduce(0) { $0 + $1.points }

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
