// APIServer/Routes/BrowserResultRoutes.swift
//
// Accepts grading results from the student's browser (Pyodide run).
// The browser runner runs tests locally and submits the notebook + results
// in one atomic call — no native worker re-run is queued.
//
//   POST /api/v1/submissions/browser-result
//
// Multipart body:
//   collection  — JSON text of a TestOutcomeCollection
//   notebook    — raw bytes of the student's .ipynb file
//   testSetupID — ID of the test setup this submission targets
//
// When in-browser grading FREEZES (a synchronous runaway loop on the Pyodide
// main thread) or fails outright, the browser never reaches the call above, so
// no row is created and the worker backstop has nothing to grade. The
// freeze-watchdog worker / browser-runner catch path instead calls:
//
//   POST /api/v1/submissions/browser-failover   (JSON: testSetupID, notebook)
//
// which enqueues a `pending` browser-mode submission for the native backstop.

import Core
import Fluent
import Foundation
import Vapor

struct BrowserResultRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let submissions = routes.grouped("api", "v1", "submissions")
        submissions.post("browser-result", use: submitBrowserResult)
        submissions.post("runner-submit", use: submitRunnerSubmission)
        submissions.post("browser-failover", use: submitBrowserFailover)
    }

    // MARK: - POST /api/v1/submissions/browser-result

    @Sendable
    func submitBrowserResult(req: Request) async throws -> BrowserResultResponse {
        let caller = try req.auth.require(APIUser.self)
        let body = try req.content.decode(BrowserResultBody.self)

        // Validate the referenced test setup exists.
        guard let setup = try await APITestSetup.find(body.testSetupID, on: req.db) else {
            throw AppError.invalidParameter(name: "testSetupID", reason: "no test setup with that ID")
        }

        try await requireCourseEnrollment(caller: caller, courseID: setup.courseID, db: req.db)
        _ = try await requireOpenStudentAssignment(for: body.testSetupID, user: caller, on: req)

        // Decode the TestOutcomeCollection the browser sent.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let collection: TestOutcomeCollection
        do {
            guard let data = body.collection.data(using: .utf8) else {
                throw AppError.invalidParameter(name: "collection", reason: "not valid UTF-8")
            }
            let decoded = try decoder.decode(TestOutcomeCollection.self, from: data)
            // Same serialized-size budget as the worker path (#1157) — keeps
            // the unbounded blob out of the results table regardless of which
            // grader produced it.
            let (bounded, didTruncate) = decoded.truncatingOversizedOutput()
            if didTruncate {
                // Submission id in metadata only — message text reaches the
                // admin query_logs buffer unredacted (compliance audit F-1).
                req.logger.warning(
                    "result_collection_truncated source=browser",
                    metadata: ["submission_id": .string(bounded.submissionID)]
                )
            }
            collection = bounded
        } catch let e as DecodingError {
            throw AppError.unprocessable(reason: "Invalid TestOutcomeCollection: \(e)")
        }

        // Persist the notebook to disk as the submission artifact.  Merge the
        // student's notebook with the instructor's canonical notebook so the
        // hidden test cells (secret, release) are present in the stored artifact:
        // no native worker runs here (browser results are stored as-is), but if
        // this submission is later re-graded by a worker (a retest, or the
        // browser-mode backstop) the authoritative suite has its cells.
        let subsDir = req.application.submissionsDirectory
        let subID = "sub_\(UUID().uuidString.lowercased().prefix(8))"
        let nbPath = subsDir + "\(subID).ipynb"
        let instructorData: Data
        do {
            // Cached (#1171): this runs per browser-graded submission, and the
            // uncached path is a serialized unzip subprocess per call.
            instructorData = try await req.application.notebookBytesCache.notebookData(
                for: NotebookSourceRef(setup))
        } catch {
            req.logger.warning(
                "Could not load instructor notebook for \(setup.id ?? "?"): \(error) — hidden test cells will not be injected"
            )
            instructorData = body.notebook
        }
        let notebookToSave = mergeNotebook(student: body.notebook, instructor: instructorData)
        // Offloaded to the NIO thread pool: a synchronous write pins a
        // cooperative-pool thread for its duration, and these are the routes a
        // whole lab section hits at once.
        try await req.fileio.writeFile(.init(data: notebookToSave), at: nbPath)

        // Create the submission record as "complete" immediately — browser
        // results are authoritative and no native worker re-run is queued.
        // The attempt number is assigned race-free inside one transaction.
        let submission = APISubmission(
            id: subID,
            testSetupID: body.testSetupID,
            zipPath: nbPath,
            attemptNumber: 0,  // assigned by saveSubmissionWithNextAttemptNumber
            status: SubmissionStatus.complete.rawValue,
            filename: "\(subID).ipynb",
            userID: caller.id,
            kind: APISubmission.Kind.student
        )
        try await saveSubmissionWithNextAttemptNumber(submission, userID: caller.id, on: req.db)
        let attemptNumber = submission.attemptNumber ?? 1

        // Persist the browser result, tagged source="browser".  The browser
        // builds its collection before it knows the server-authoritative attempt
        // number, so it always stamps attemptNumber=1 (and isFirstPassSuccess for
        // every pass).  Reconcile those fields — and the submission ID — from the
        // values the server derived above so the stored result agrees with the
        // submission row and the First-Try-Perfect badge / per-attempt analytics
        // stay correct for browser-graded assignments.
        let reconciled = Self.reconcileBrowserCollection(
            collection, submissionID: subID, attemptNumber: attemptNumber)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let collectionJSON = try String(data: encoder.encode(reconciled), encoding: .utf8) ?? "{}"

        let browserResult = APIResult(
            id: "res_\(UUID().uuidString.lowercased().prefix(8))",
            submissionID: subID,
            source: "browser"
        )
        // Mark for BrightSpace sync exactly as the worker path does. Without
        // this a browser-graded assignment never auto-pushed a grade to LEARN:
        // the 60-second sweep only ever sees rows flagged here, so notebook
        // labs silently reached LEARN only via an instructor's manual "Push
        // all" or a retest that routed through a worker.
        try await flagResultForBrightSpaceSync(
            browserResult, testSetupID: body.testSetupID, application: req.application, on: req.db)
        // Same transient-SQLite-lock guard as the submission insert above: this
        // second write can also lose a race with a concurrent commit (session
        // write / background monitor) and surface as a 500 otherwise.
        // saveWithCollection is itself transactional (row + blob together).
        try await withTransientDatabaseLockRetry(on: req.db) {
            try await browserResult.saveWithCollection(json: collectionJSON, on: req.db)
        }

        req.logger.info("Browser result stored for \(subID)")

        await awardBrowserResultBadges(
            req: req, setup: setup, userID: caller.id, submissionID: subID,
            reconciled: reconciled, attemptNumber: attemptNumber)

        // Update the student's server-side working copy with what they just
        // submitted. Without this, the working copy stays as the blank starter
        // template forever, so students who return to the assignment (or open
        // it on a different device) would have their editor re-seeded with the
        // blank template instead of their latest submitted work.
        // Use the student's own notebook (body.notebook) — not notebookToSave,
        // which contains the instructor's injected hidden-test cells.
        if let userID = caller.id {
            _ = try? await ensureUserNotebookWorkingCopy(
                req: req,
                setupID: body.testSetupID,
                userID: userID,
                fallbackSetup: setup,
                overwriteWith: body.notebook
            )
        }

        return BrowserResultResponse(submissionID: subID)
    }

    /// Everything a stored browser result triggers that is NOT the grade.
    ///
    /// Extracted so the ordering is visible at the call site: the result is
    /// saved, and only then does any of this run. See the notes inside.
    private func awardBrowserResultBadges(
        req: Request, setup: APITestSetup, userID: UUID?, submissionID subID: String,
        reconciled: TestOutcomeCollection, attemptNumber: Int
    ) async {
        // ── Everything below here is a SIDE EFFECT, and none of it may fail
        // the submission. ────────────────────────────────────────────────────
        //
        // The grade is stored as of the line above. Anything that throws after
        // it turns a submission that graded perfectly into a 500 the browser
        // reports as "Failed to submit results" — while the row sits in the
        // database, so the page polls it forever and never renders a result.
        // That is the documented `grading-probe` intermittent
        // (docs/ci-flakiness.md, Family 2's "not the exec-hang" note): three
        // sightings, each with `suite_done` reached and the POST 500ing after.
        //
        // The Pathfinder award used to run BEFORE the result save, which is
        // what made the window lossy rather than merely noisy — the submission
        // row existed and the result did not. It moved down here.
        //
        // Why these throw at all, when SQLite is meant to wait: sqlite-nio
        // installs a busy handler that retries forever, so ordinary contention
        // never surfaces. What it cannot cover is `SQLITE_BUSY_SNAPSHOT` — a
        // WAL read snapshot that has gone stale because another connection
        // committed in between — which SQLite returns IMMEDIATELY, bypassing
        // the handler, because waiting cannot help. Only starting the
        // transaction again can, which is what `withTransientDatabaseLockRetry`
        // does. Every badge helper here is read-then-write, the exact shape
        // that hits it, and the page's own result polling supplies the
        // concurrent commits.
        //
        // Retried first (a transient race should still award the badge), and
        // logged rather than thrown if it survives the retries. A class badge
        // is worth an ordinary amount; a student's grade is not worth losing
        // for one.
        func bestEffort(_ what: String, _ work: () async throws -> Void) async {
            do {
                try await withTransientDatabaseLockRetry(on: req.db) { try await work() }
            } catch {
                req.logger.warning(
                    "browser_result_side_effect_failed \(what) for \(subID): \(error)")
            }
        }

        // First-to-submit records (Pathfinder): notebook submissions are the
        // dominant flow, but only the zip-upload handler used to award this —
        // browser-graded assignments never had a Pathfinder (audit A2).
        if let userID {
            await bestEffort("first_to_submit") {
                try await awardFirstToSubmitRecords(
                    setup: setup, userID: userID, submissionID: subID, on: req.db)
            }
        }

        // Class records (Trailblazer / fastest / fewest-attempts) on a 100%
        // browser grade.  These were only awarded in the worker report handler,
        // so browser-graded assignments never awarded any record unless a
        // retest or the failover backstop happened to route through a worker
        // (audit A2).  Same rounded-percent gate and student-role guard as
        // `ResultRoutes`; the reconciled collection carries the
        // server-authoritative attempt number.
        // The class-wide union of covered items. Outside the 100% gate below,
        // because coverage is per item rather than per student — and wired here
        // as well as in `ResultRoutes` for the reason the comment above records:
        // a side effect wired at only one ingest path silently reports half the
        // class as the whole of it.
        if reconciled.buildStatus == .passed, let userID {
            await bestEffort("class_item_coverage") {
                try await recordClassItemCoverage(
                    testSetupID: setup.id ?? "",
                    userID: userID,
                    submissionID: subID,
                    outcomes: reconciled.outcomes,
                    on: req.db
                )
            }
        }

        if reconciled.buildStatus == .passed,
            let userID,
            gradePercent(from: reconciled) == 100
        {
            await bestEffort("class_badges") {
                try await awardClassBadgesFor100Percent(
                    testSetupID: setup.id ?? "",
                    userID: userID,
                    submissionID: subID,
                    executionTimeMs: reconciled.executionTimeMs,
                    attemptNumber: attemptNumber,
                    disabled: BuiltInAchievements.disabled(in: setup),
                    on: req.db
                )
            }
        }

    }

    // MARK: - POST /api/v1/submissions/runner-submit

    @Sendable
    func submitRunnerSubmission(req: Request) async throws -> RunnerSubmissionResponse {
        let caller = try req.auth.require(APIUser.self)
        let body = try req.content.decode(RunnerSubmitBody.self)

        guard let setup = try await APITestSetup.find(body.testSetupID, on: req.db) else {
            throw AppError.invalidParameter(name: "testSetupID", reason: "no test setup with that ID")
        }

        try await requireCourseEnrollment(caller: caller, courseID: setup.courseID, db: req.db)
        _ = try await requireOpenStudentAssignment(for: body.testSetupID, user: caller, on: req)

        let manifestData = Data(setup.manifest.utf8)
        if let manifest = decodeManifest(from: manifestData),
            manifest.effectiveGradingMode == .browser
        {
            throw AppError.badRequest(
                reason: "Browser-graded assignments must be submitted through the browser runner.")
        }

        let subsDir = req.application.submissionsDirectory
        let subID = "sub_\(UUID().uuidString.lowercased().prefix(8))"
        let nbPath = subsDir + "\(subID).ipynb"

        // Always merge with canonical instructor notebook so hidden tests are present.
        let instructorData: Data
        do {
            // Cached (#1171): this runs per browser-graded submission, and the
            // uncached path is a serialized unzip subprocess per call.
            instructorData = try await req.application.notebookBytesCache.notebookData(
                for: NotebookSourceRef(setup))
        } catch {
            req.logger.warning(
                "Could not load instructor notebook for \(setup.id ?? "?"): \(error) — hidden test cells will not be injected"
            )
            instructorData = body.notebook
        }
        let notebookToSave = mergeNotebook(student: body.notebook, instructor: instructorData)
        // Offloaded to the NIO thread pool: a synchronous write pins a
        // cooperative-pool thread for its duration, and these are the routes a
        // whole lab section hits at once.
        try await req.fileio.writeFile(.init(data: notebookToSave), at: nbPath)

        let submittedFilename = normalizedNotebookFilename(body.filename)
        let submission = APISubmission(
            id: subID,
            testSetupID: body.testSetupID,
            zipPath: nbPath,
            attemptNumber: 0,  // assigned by saveSubmissionWithNextAttemptNumber
            status: SubmissionStatus.pending.rawValue,
            filename: submittedFilename,
            userID: caller.id,
            kind: APISubmission.Kind.student
        )
        try await saveSubmissionWithNextAttemptNumber(submission, userID: caller.id, on: req.db)

        // First-to-submit records (Pathfinder) — same as the zip-upload and
        // browser-result paths (audit A2).
        if let userID = caller.id {
            try await awardFirstToSubmitRecords(
                setup: setup, userID: userID, submissionID: subID, on: req.db)
        }

        // For browser-mode test setups the client-side WASM runner picks up the job;
        // waking the local native runner would waste resources and claim nothing
        // (WorkerJobRoutes filters out browser-mode submissions).
        let isWorkerMode =
            (decodeManifest(from: manifestData))
            .map { $0.effectiveGradingMode == .worker } ?? true
        if isWorkerMode {
            await ensureLocalRunnerForSubmissionIfNeeded(req: req)
        }

        return RunnerSubmissionResponse(submissionID: subID)
    }

    // MARK: - POST /api/v1/submissions/browser-failover

    /// Enqueues a server-side ("worker backstop") grade for a browser-graded
    /// submission whose in-browser Pyodide run failed or *froze*.
    ///
    /// Browser grading runs Pyodide on the page's main thread, so a synchronous
    /// runaway loop in student code hard-freezes the tab: the in-browser per-test
    /// timeout (a `Promise.race` against a timer) can't fire on the blocked
    /// thread, grading never completes, and `browser-result` is never POSTed — so
    /// no submission row is ever created and the v0.4.56 worker backstop (which
    /// only grades *pending* browser-mode rows) has nothing to claim. The student
    /// is stuck on "Testing…" forever.
    ///
    /// This endpoint closes that gap. The page's freeze-watchdog worker — which
    /// keeps running on its own thread while the main thread is frozen — calls it
    /// with the notebook bytes it stashed before grading began; the browser-runner
    /// catch path also calls it on a non-freeze hard failure. It creates a
    /// `pending`, browser-mode student submission so the existing native backstop
    /// grades the `.py` scripts via `python3` — where a runaway loop is SIGKILLed
    /// and reported as a clean `timeout` instead of a dead kernel.
    ///
    /// Gated identically to `browser-result` (enrollment + effective-open), so a
    /// closed or overdue assignment can't be graded via the failover either.
    /// Idempotent per (student, setup): a repeated fire (watchdog + catch path,
    /// retries, reloads) reuses the existing queued/in-flight row instead of
    /// piling up duplicates.
    @Sendable
    func submitBrowserFailover(req: Request) async throws -> RunnerSubmissionResponse {
        let caller = try req.auth.require(APIUser.self)
        let body = try req.content.decode(BrowserFailoverBody.self)

        guard let setup = try await APITestSetup.find(body.testSetupID, on: req.db) else {
            throw AppError.invalidParameter(name: "testSetupID", reason: "no test setup with that ID")
        }

        try await requireCourseEnrollment(caller: caller, courseID: setup.courseID, db: req.db)
        _ = try await requireOpenStudentAssignment(for: body.testSetupID, user: caller, on: req)

        // The failover only applies to browser-graded setups — worker-graded
        // assignments already enqueue through `runner-submit` and can't freeze a
        // browser kernel. Reject the inverse so a stray call can't smuggle a
        // worker-mode submission in through this path.
        let manifestData = Data(setup.manifest.utf8)
        guard let manifest = decodeManifest(from: manifestData),
            manifest.effectiveGradingMode == .browser
        else {
            throw AppError.badRequest(
                reason: "Browser failover is only for browser-graded assignments.")
        }

        guard let userID = caller.id else {
            throw AppError.internalFailure(reason: "Authenticated user has no ID")
        }

        // Idempotency: a browser-mode setup never has `pending`/`assigned` student
        // rows except failovers (normal browser submissions are stored `complete`),
        // so an existing one is an earlier failover for this same attempt — reuse
        // it rather than enqueue a duplicate grade.
        if let existing = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == body.testSetupID)
            .filter(\.$kind == APISubmission.Kind.student)
            .filter(\.$userID == userID)
            .filter(\.$status ~~ [SubmissionStatus.pending.rawValue, SubmissionStatus.assigned.rawValue])
            .first()
        {
            return RunnerSubmissionResponse(submissionID: existing.id ?? "")
        }

        // Persist the notebook artifact, merged with the instructor notebook so
        // the backstop runs the hidden (release/secret) test cells too — exactly
        // as `browser-result` does.
        let subsDir = req.application.submissionsDirectory
        let subID = "sub_\(UUID().uuidString.lowercased().prefix(8))"
        let nbPath = subsDir + "\(subID).ipynb"
        let studentData = Data(body.notebook.utf8)
        let instructorData: Data
        do {
            instructorData = try await req.application.notebookBytesCache.notebookData(
                for: NotebookSourceRef(setup))
        } catch {
            req.logger.warning(
                "Browser failover: could not load instructor notebook for \(setup.id ?? "?"): \(error) — hidden test cells will not be injected"
            )
            instructorData = studentData
        }
        let notebookToSave = mergeNotebook(student: studentData, instructor: instructorData)
        // Offloaded to the NIO thread pool: a synchronous write pins a
        // cooperative-pool thread for its duration, and these are the routes a
        // whole lab section hits at once.
        try await req.fileio.writeFile(.init(data: notebookToSave), at: nbPath)

        let submission = APISubmission(
            id: subID,
            testSetupID: body.testSetupID,
            zipPath: nbPath,
            attemptNumber: 0,  // assigned by saveSubmissionWithNextAttemptNumber
            status: SubmissionStatus.pending.rawValue,
            filename: "\(subID).ipynb",
            userID: userID,
            kind: APISubmission.Kind.student
        )
        try await saveSubmissionWithNextAttemptNumber(submission, userID: userID, on: req.db)

        // A failover row IS the student's real submission for this attempt —
        // if they're the first in the class to submit, the frozen browser run
        // must not cost them the record (audit A2).
        try await awardFirstToSubmitRecords(
            setup: setup, userID: userID, submissionID: subID, on: req.db)

        req.logger.warning(
            "Browser grading failed/froze for setup \(body.testSetupID); enqueued worker backstop grade \(subID)"
        )

        // Record a diagnostic breadcrumb so the freeze→failover is visible in the
        // admin browser-diagnostics surface next to the watchdog_timeout /
        // kernel-unhealthy events that precede it. Infrastructure-only (a
        // submission id), never student content.
        let diagnostic = APIClientDiagnostic(
            userID: userID,
            testSetupID: body.testSetupID,
            kind: "submit_failover",
            failedChecks: nil,
            userAgent: req.headers.first(name: .userAgent).map { String($0.prefix(512)) },
            message: "submission=\(subID)",
            source: "backstop"
        )
        try? await diagnostic.save(on: req.db)

        // Wake a local runner in development (production runners poll
        // continuously). The backstop claims browser-mode pending rows, so unlike
        // `runner-submit` we DO want to nudge the runner for a browser setup here.
        await ensureLocalRunnerForSubmissionIfNeeded(req: req)

        return RunnerSubmissionResponse(submissionID: subID)
    }

    /// Rewrites a browser-supplied collection with the server-authoritative
    /// submission ID and attempt number, recomputing `isFirstPassSuccess` from
    /// the true attempt (a pass only counts as a first-pass success on attempt
    /// 1).  Everything else is carried through verbatim.
    static func reconcileBrowserCollection(
        _ collection: TestOutcomeCollection, submissionID: String, attemptNumber: Int
    ) -> TestOutcomeCollection {
        let outcomes = collection.outcomes.map { o in
            TestOutcome(
                testName: o.testName,
                testClass: o.testClass,
                tier: o.tier,
                status: o.status,
                shortResult: o.shortResult,
                longResult: o.longResult,
                score: o.score,
                points: o.points,
                executionTimeMs: o.executionTimeMs,
                memoryUsageBytes: o.memoryUsageBytes,
                attemptNumber: attemptNumber,
                isFirstPassSuccess: attemptNumber == 1 && o.status == .pass)
        }
        // Recompute the weighted, partial-credit grade server-side rather than
        // trusting the browser's aggregate — older browser artifacts omit it (so
        // it would default to the unweighted passCount), and once the wasm is
        // re-vendored each outcome carries its own `score`.  totalPoints sums the
        // weights; earnedPoints sums points × score.
        let totalPoints = outcomes.reduce(0) { $0 + $1.points }
        let earnedPoints = outcomes.reduce(0.0) { $0 + Double($1.points) * $1.score }
        return TestOutcomeCollection(
            submissionID: submissionID,
            testSetupID: collection.testSetupID,
            attemptNumber: attemptNumber,
            buildStatus: collection.buildStatus,
            compilerOutput: collection.compilerOutput,
            outcomes: outcomes,
            totalTests: collection.totalTests,
            passCount: collection.passCount,
            failCount: collection.failCount,
            errorCount: collection.errorCount,
            timeoutCount: collection.timeoutCount,
            executionTimeMs: collection.executionTimeMs,
            totalPoints: totalPoints,
            earnedPoints: earnedPoints,
            warnings: collection.warnings,
            jobStartedAt: collection.jobStartedAt,
            runnerVersion: collection.runnerVersion,
            timestamp: collection.timestamp)
    }
}

// MARK: - Request / Response types

struct BrowserResultBody: Content {
    /// JSON-encoded TestOutcomeCollection from Pyodide.
    var collection: String
    /// Raw bytes of the student's .ipynb file.
    var notebook: Data
    /// The test setup this submission belongs to.
    var testSetupID: String
}

struct RunnerSubmitBody: Content {
    var notebook: Data
    var testSetupID: String
    var filename: String?
}

struct BrowserFailoverBody: Content {
    /// The test setup this submission belongs to.
    var testSetupID: String
    /// Raw `.ipynb` JSON text the browser stashed before grading began. Sent as
    /// a string (not multipart) so the freeze-watchdog worker can post it with a
    /// plain JSON `fetch` from its own thread while the main thread is frozen.
    var notebook: String
}

struct BrowserResultResponse: Content {
    /// ID of the submission record (status: complete).
    let submissionID: String
}

struct RunnerSubmissionResponse: Content {
    let submissionID: String
}

private func normalizedNotebookFilename(_ filename: String?) -> String {
    guard var value = filename?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return "submission.ipynb"
    }
    value = URL(fileURLWithPath: value).lastPathComponent
    value = value.replacingOccurrences(of: "/", with: "-")
    value = value.replacingOccurrences(of: "\\", with: "-")
    if !value.lowercased().hasSuffix(".ipynb") {
        value += ".ipynb"
    }
    return value
}
