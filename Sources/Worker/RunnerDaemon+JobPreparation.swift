// Worker/RunnerDaemon+JobPreparation.swift
//
// The prepare phase of a job: fetch the submission and the test setup,
// stage the submission into the grading workspace, normalize it, run the
// optional `make` step, write the per-student files and the runtime helpers,
// and stage any opponents. Split from RunnerDaemon+JobProcessing.swift
// (#1799).

import Core
import Foundation

extension WorkerDaemon {

    /// Runs the submission download and the test-setup acquire concurrently,
    /// and returns what each one did.  The test setup is served from the LRU
    /// cache: on a hit the cached directory is copied into a fresh scratch
    /// location; on a miss it is downloaded, unzipped, committed to cache,
    /// then copied.
    ///
    /// BOTH legs report a `Result` and BOTH are always awaited, so neither
    /// one's failure can leave this scope while the other is still
    /// transferring.  That is not a style choice.  Leaving an `async let`
    /// scope early cancels the sibling child, and cancelling an in-flight
    /// `URLSession.download` on Linux deadlocks: `swift_asyncLet_finish` →
    /// `swift_task_cancel` takes the child task's status-record lock and then
    /// `DispatchQueue.sync`s onto the session's work queue, while that same
    /// work queue is completing the child's transfer and resuming its
    /// continuation — which needs the very lock the canceller is holding.
    /// Neither side moves and the cooperative pool fills up behind them
    /// (Family 4 in docs/ci-flakiness.md; `worker-tests` SIGABRTing at the
    /// wedge watchdog's five-minute mark).  Several tests point both URLs at a
    /// 404 server, which made the racing shape hit it routinely.
    ///
    /// Deliberate cancellation is deliberately NOT weakened.  The download
    /// stays a *structured child* of the job task, so cancelling the daemon
    /// still tears an in-flight submission transfer down — exactly as
    /// cancelling an `acquire` still cancels the shared populate task once its
    /// last waiter detaches (#1233).  What is removed is only the incidental
    /// cancellation one leg's failure used to inflict on the other.
    func fetchJobArtifacts(job: Job, paths: JobWorkspacePaths) async -> JobArtifactFetch {
        async let submissionDownload: Result<Void, any Error> = {
            do {
                try await download(url: job.submissionURL, to: paths.submissionZip, stage: .downloadSubmission)
                return .success(())
            } catch {
                return .failure(error)
            }
        }()

        let testSetupAcquireStartedAt = Date()
        let cacheKey = testSetupCacheKey(for: job)
        let testSetup: Result<TestSetupCache.AcquireResult, any Error>
        do {
            testSetup = .success(
                try await testSetupCache.acquire(testSetupID: cacheKey) {
                    let stagingZip = paths.workDir.appendingPathComponent("testsetup.zip")
                    let stagingDir = paths.workDir.appendingPathComponent(
                        "testsetup_staging", isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: stagingDir, withIntermediateDirectories: true)
                    try await self.download(url: job.testSetupURL, to: stagingZip, stage: .downloadTestSetup)
                    try await extractZipArchive(zipPath: stagingZip.path, into: stagingDir)
                    return stagingDir
                })
        } catch {
            testSetup = .failure(error)
        }
        let acquireMilliseconds = Int(Date().timeIntervalSince(testSetupAcquireStartedAt) * 1000)

        // Reached on every path, including both failures — this join is what
        // keeps either leg from ever being cancelled by the other's throw.
        return JobArtifactFetch(
            submission: await submissionDownload,
            testSetup: testSetup,
            testSetupAcquireMilliseconds: acquireMilliseconds
        )
    }

    /// Stages the opponent of a match job and every opponent of a matrix job
    /// (docs/class-activities.md). A throw here is the job's build failure,
    /// like a missing personalized file: a match with nobody on the other
    /// side would read as a win, and the message names the fix. A submission
    /// opponent (a champion, a classmate) is downloaded first, through the
    /// same retrying download the challenger's own upload gets. A matrix job
    /// stages every opponent up front, each in its own directory, so a
    /// download failure fails the job before any match is played rather than
    /// after most of them.
    func stageOpponents(
        job: Job, paths: JobWorkspacePaths, testSetupDir: URL
    ) async throws -> (single: URL?, matrix: [URL]) {
        var downloadedOpponent: URL?
        if let url = job.opponent?.submissionURL {
            let destination = opponentDownloadDestination(workDir: paths.workDir)
            try await download(url: url, to: destination, stage: .downloadOpponent)
            downloadedOpponent = destination
        }
        let single = try await stageOpponentWorkspace(
            job: job, workDir: paths.workDir, testSetupDir: testSetupDir,
            downloadedSubmission: downloadedOpponent)
        let matrix = try await stageMatrixOpponents(job: job, paths: paths, testSetupDir: testSetupDir)
        return (single, matrix)
    }

    /// How many matrix opponents are downloaded and staged at once. A matrix
    /// job plays every other student in the class, and one at a time it sat
    /// on a round trip per classmate before the first match ran. A constant,
    /// not configuration.
    static let opponentStagingWidth = 8

    /// Downloads and stages every opponent of a matrix job, at most
    /// `opponentStagingWidth` at a time, and returns their directories in
    /// `job.opponents` order.
    ///
    /// The job fails with the error a one-at-a-time loop would throw: the
    /// first failing opponent in `job.opponents` order, and its download's
    /// error before its staging's. Opponents are started in index order and
    /// none is started after a failure, so every opponent before the first
    /// failure has run to its end. A later opponent already in flight then
    /// finishes too; its files stay in the work dir, which is removed with
    /// the job.
    ///
    /// No child throws and the group is never cancelled, so one opponent's
    /// failure never cancels another's in-flight download. That cancellation
    /// deadlocks on Linux (see `fetchJobArtifacts`). Cancelling the job still
    /// cancels every child, as it cancelled the loop.
    private func stageMatrixOpponents(
        job: Job, paths: JobWorkspacePaths, testSetupDir: URL
    ) async throws -> [URL] {
        let opponents = job.opponents ?? []
        guard !opponents.isEmpty else { return [] }
        var results = [Result<URL, any Error>?](repeating: nil, count: opponents.count)
        await withTaskGroup(of: (Int, Result<URL, any Error>).self) { group in
            var nextIndex = 0
            var sawFailure = false
            func startNext() {
                let index = nextIndex
                group.addTask {
                    await self.stageMatrixOpponent(
                        opponents[index], index: index, job: job, paths: paths, testSetupDir: testSetupDir)
                }
                nextIndex += 1
            }
            while nextIndex < min(Self.opponentStagingWidth, opponents.count) { startNext() }
            while let (index, result) = await group.next() {
                results[index] = result
                if case .failure = result { sawFailure = true }
                if !sawFailure, nextIndex < opponents.count { startNext() }
            }
        }
        var matrix: [URL] = []
        for result in results {
            // Nil only after a failure at a lower index, which threw first.
            guard let result else { break }
            matrix.append(try result.get())
        }
        return matrix
    }

    /// One opponent of a matrix job: its download, when it has a
    /// submission, then its staging into `opponent-<index>/`. Never throws;
    /// the first error is the result. Off the actor, like the staging it
    /// awaits; only the download's bookkeeping hops back.
    @concurrent
    nonisolated private func stageMatrixOpponent(
        _ opponent: JobOpponent, index: Int, job: Job, paths: JobWorkspacePaths, testSetupDir: URL
    ) async -> (Int, Result<URL, any Error>) {
        do {
            var downloaded: URL?
            if let url = opponent.submissionURL {
                let destination = opponentDownloadDestination(workDir: paths.workDir, index: index)
                try await download(url: url, to: destination, stage: .downloadOpponent)
                downloaded = destination
            }
            let staged = try await stageOpponent(
                opponent, manifest: job.manifest,
                into: opponentDirectory(workDir: paths.workDir, index: index),
                testSetupDir: testSetupDir, downloadedSubmission: downloaded)
            return (index, .success(staged))
        } catch {
            return (index, .failure(error))
        }
    }

    /// Downloads + unzips the submission and test setup, stages the
    /// submission into the test workspace, runs the optional `make` step,
    /// and installs the runtime helpers.  Returns a `JobPreparedWorkspace`
    /// that the caller hands to `executeTestSuites`.
    func prepareJobWorkspace(
        job: Job,
        paths: JobWorkspacePaths,
        stageTimings: inout JobStageTimings
    ) async throws -> JobPreparedWorkspace {
        let fetchStartedAt = Date()
        let fetched = await fetchJobArtifacts(job: job, paths: paths)
        let submissionOutcome = fetched.submission

        // A failed acquire produced no scratch directory, so there is nothing
        // to clean up and nothing to report from the submission leg; its error
        // is the job's error, matching the pre-reconciliation ordering where
        // `acquire` was awaited first.
        let acquireResult = try fetched.testSetup.get()
        let testSetupDir = acquireResult.directory
        stageTimings.record(
            "test_setup_acquire",
            milliseconds: fetched.testSetupAcquireMilliseconds
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
            try submissionOutcome.get()
            stageTimings.record(
                "submission_download",
                milliseconds: Int(Date().timeIntervalSince(fetchStartedAt) * 1000)
            )

            let manifest = job.manifest

            try await stageSubmissionIntoWorkspace(
                job: job,
                paths: paths,
                stageTimings: &stageTimings
            )

            try await removeStarterNotebookIfPresent(
                manifest: manifest,
                testSetupDir: testSetupDir,
                submissionFilename: job.submissionFilename,
                stageTimings: &stageTimings
            )

            let (normalizationWarnings, preferredStudentModule) = try await normalizeSubmission(
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

            // Per-student inputs and dataset slices (`materializePersonalizedFiles`).
            // Off the actor, like the other workspace writes (#2779).
            try await runOffActor { () throws in
                try materializePersonalizedFiles(job: job, into: testSetupDir)
            }

            // Install the shared test runtime helpers for every run. The set is
            // walked from `AssignmentLanguage.allCases` rather than written out
            // here — see `writeRuntimeHelpers` for what the hand-written list
            // cost. Timed inline, as the make step is, so the writes can run
            // off the actor (#2779).
            let runtimeHelperStartedAt = Date()
            try await runOffActor { () throws in
                try self.writeRuntimeHelpers(in: testSetupDir)
                try self.writeStudentModuleHint(in: testSetupDir, preferredFilename: preferredStudentModule)
            }
            stageTimings.record(
                "runtime_helper_setup",
                milliseconds: Int(Date().timeIntervalSince(runtimeHelperStartedAt) * 1000))

            // Timed inline, as the make step is: `measure`'s closure cannot
            // hop to this actor's isolation for the download.
            let opponentStartedAt = Date()
            let (opponentDir, opponentDirs) = try await stageOpponents(
                job: job, paths: paths, testSetupDir: testSetupDir)
            stageTimings.record(
                "opponent_setup", milliseconds: Int(Date().timeIntervalSince(opponentStartedAt) * 1000))

            return JobPreparedWorkspace(
                testSetupDir: testSetupDir,
                manifest: manifest,
                normalizationWarnings: normalizationWarnings,
                opponentDir: opponentDir,
                opponentDirs: opponentDirs
            )
        } catch {
            await removeWorkspaceItemOffActor(at: testSetupDir, label: "test_setup_dir", job: job)
            throw error
        }
    }

    /// Stage the submission independently from the grading workspace so the
    /// worker can normalize it without mutating the raw artifact.
    ///
    /// `@concurrent nonisolated`, so the copy runs off the daemon actor
    /// (#2779). It reads no actor state. The copy itself goes through
    /// `runOffActor`, so it does not hold a cooperative-pool thread either.
    @concurrent
    nonisolated func stageSubmissionIntoWorkspace(
        job: Job,
        paths: JobWorkspacePaths,
        stageTimings: inout JobStageTimings
    ) async throws {
        try await stageTimings.measure("submission_unpack") {
            if let filename = job.submissionFilename {
                try await runOffActor { () throws in
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
                }
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
    ///
    /// The removal runs off the actor (#2779). It is timed inline, as the
    /// make step is, and a failure records no timing, as before.
    func removeStarterNotebookIfPresent(
        manifest: RunnerManifest,
        testSetupDir: URL,
        submissionFilename: String?,
        stageTimings: inout JobStageTimings
    ) async throws {
        let startedAt = Date()
        try await runOffActor { () throws in
            let starterName = manifest.starterNotebook ?? "assignment.ipynb"
            let starterPath = testSetupDir.appendingPathComponent(starterName)
            if FileManager.default.fileExists(atPath: starterPath.path),
                submissionFilename != starterName
            {
                try FileManager.default.removeItem(at: starterPath)
            }
        }
        stageTimings.record("starter_cleanup", milliseconds: Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    /// `@concurrent nonisolated`, so the merge and the notebook extraction
    /// run off the daemon actor (#2779). It reads no actor state. The
    /// synchronous merge-and-extract arm goes through `runOffActor`, so its
    /// copies and its walk of the workspace do not hold a cooperative-pool
    /// thread either.
    @concurrent
    nonisolated func normalizeSubmission(
        job: Job,
        manifest: RunnerManifest,
        paths: JobWorkspacePaths,
        testSetupDir: URL,
        stageTimings: inout JobStageTimings
    ) async throws -> ([String], String?) {
        try await stageTimings.measure("submission_prepare") {
            // A `switch` rather than `if …== .pythonModule`, so the extraction
            // language is BOUND by the routing decision instead of re-derived
            // here. This block used to re-ask the question twice —
            // `targetsR ? .r : nil` for the extractor and `targetsR ? .r :
            // .python` for the student-module hint — and both ternaries
            // type-check for any number of languages while sending every one
            // after R down the Python branch.
            switch submissionNormalization(
                manifest: manifest,
                submissionFilename: job.submissionFilename,
                submissionDirectory: paths.submissionDir)
            {
            case .pythonModule:
                let normalizer = SubmissionNormalizer()
                let normalization = try await normalizer.normalizePythonSubmission(
                    manifest: manifest,
                    submissionDirectory: paths.submissionDir,
                    workspaceDirectory: testSetupDir,
                    submissionFilename: job.submissionFilename
                )
                return (normalization.warnings, normalization.preferredStudentModule)

            case .extractToSource(let forcedLanguage):
                return try await runOffActor { () throws -> ([String], String?) in
                    try mergeAndExtractSubmission(
                        job: job, manifest: manifest, paths: paths, testSetupDir: testSetupDir,
                        forcedLanguage: forcedLanguage)
                }
            }
        }
    }
}

/// The `.extractToSource` arm of `normalizeSubmission`: merges the
/// submission into the workspace, extracts every notebook to source in
/// the routed language, and names the student's module. Synchronous, so
/// it runs whole through `runOffActor`. A free function, so the closure
/// that runs it captures no daemon state.
private func mergeAndExtractSubmission(
    job: Job,
    manifest: RunnerManifest,
    paths: JobWorkspacePaths,
    testSetupDir: URL,
    forcedLanguage: AssignmentLanguage?
) throws -> ([String], String?) {
    // The student's upload must not be able to replace the tests it
    // is about to be graded by (#1357). Skipped files are warned
    // about rather than dropped silently.
    let protected = protectedWorkspaceFilenames(manifest: manifest)
    let refused = try mergeDirectoryContents(
        from: paths.submissionDir,
        into: testSetupDir,
        protected: protected)
    // A suite owned by a non-default language extracts every notebook
    // to THAT source, regardless of the submission's kernelspec (the
    // in-browser editor can rewrite it) — so the student-module hint
    // has to name the same file, or it points at a path that was
    // never written.
    // The student's own filename is passed so the submission
    // guarantees apply to it and not to an instructor's helper
    // notebook sitting in the same merged workspace.
    let warnings = try extractNotebooksToCode(
        in: testSetupDir,
        forcedLanguage: forcedLanguage,
        studentNotebookName: job.submissionFilename.map {
            URL(fileURLWithPath: $0).lastPathComponent
        },
        protected: protected)
    // nil `forcedLanguage` means the extractor trusted the
    // notebook's own metadata, which for an unrecognised kernel
    // falls back to Python — so the hint has to agree. Spelled
    // `?? .python` at the call site rather than behind a named
    // constant: `no-language-defaults.sh` permits a nil-coalescing
    // fallback precisely because it stays VISIBLE here, and hiding
    // it behind a name is the shape that guard exists to prevent.
    let hintLanguage = forcedLanguage ?? .python
    // The hint names the student's file. When the upload carries no
    // filename — every ARCHIVE submission, since a zip stores nil —
    // it is derived from what the submission directory actually
    // held, which is the only place the student's own files can
    // still be told apart from the instructor's. Without it the
    // generated C++ wrapper globbed the merged workspace and graded
    // `helpers.cpp` instead of `solution.cpp` (#1390).
    let studentModule =
        preferredStudentModuleFilename(
            submissionFilename: job.submissionFilename,
            language: hintLanguage)
        ?? studentModuleFromSubmittedFiles(
            in: paths.submissionDir, language: hintLanguage)
    return (refused.map(protectedFileSkippedWarning) + warnings, studentModule)
}

/// Writes a job's per-student files into the grading workspace: the inputs
/// file in the job's language, and each dataset slice by its bare name. Every
/// failure throws, so the job reports `buildStatus: failed` and stays
/// retestable instead of grading a student against the wrong values.
///
/// A free function, not a `WorkerDaemon` method, so its refusals are tested
/// without a daemon (#1799).
func materializePersonalizedFiles(job: Job, into testSetupDir: URL) throws {
    // Materialize per-student personalization inputs (issue #461) into the
    // grading workspace as `_ck_inputs.py` (Python) or `_ck_inputs.R` (R),
    // so generated pattern-family scripts / hand-authored tests that
    // reference per-student args / expected can load them by path. Each
    // value is already a source literal in the job's language (`repr` /
    // `deparse`) resolved server-side; `AssignmentLanguage.renderInputsFile`
    // owns the exact bytes (the Python form is byte-for-byte the historical
    // writer, so existing Python jobs are unchanged). The filename is
    // reserved (excluded from student-module candidates in the runtimes), so
    // it can't be mistaken for the submission.
    //
    // A job carrying inputs but naming no language is REFUSED rather than
    // rendered as Python. This used to default, on the reasoning that nil
    // meant an older server — but the two states it conflated are not
    // equally harmless. The values arrive as source literals already
    // rendered in the assignment's language (`repr` / `deparse`), so
    // writing them into `_ck_inputs.py` for an R assignment does not
    // produce an error at the boundary: it produces a file whose contents
    // are wrong, and every personalized test then fails somewhere inside
    // the student's own code, with a traceback that reads as their
    // mistake and persists as their grade. Guessing is only safe where
    // being wrong is loud, and here it is silent.
    //
    // Nothing legitimate reaches this. Personalization is resolved
    // per-language on the server, so an assignment with inputs has a
    // language by construction; a plain `.sh` suite has no language and
    // no inputs, and never enters this branch.
    if let inputs = job.personalizedInputs, !inputs.isEmpty {
        guard let language = job.language else {
            throw WorkerDaemonError.personalizedInputsWithoutLanguage(inputCount: inputs.count)
        }
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
}
