// APIServer/Routes/Web/RunnerValidationHelpers.swift
//
// Validation-submission lifecycle: enqueue from a saved solution
// notebook, schedule after a suite edit (debounced + runner availability
// pre-check), wait for the worker to complete, and the bulk re-test
// helper that re-queues every student submission for a setup.  Plus the
// runner-availability probes that gate validation so we don't sit in
// queue forever when no compatible runner exists.  Extracted from
// AssignmentHelpers.swift (issue #442) — no behaviour changes.

import Core
import Fluent
import Foundation
import Vapor

enum RunnerValidationOutcome {
    case passed(summary: String)
    case failed(summary: String)
    case timedOut
}

func enqueueRunnerValidationSubmission(
    req: Request,
    setupID: String,
    solutionNotebookData: Data,
    filename: String = "solution.ipynb",
    submitterUserID: UUID? = nil
) async throws -> String {
    let sanitizedFilename = submissionFilenameForStorage(
        uploadedName: filename,
        fallback: "solution.ipynb"
    )
    let submissionsDir = req.application.submissionsDirectory
    let subID = "sub_\(UUID().uuidString.lowercased().prefix(8))"
    let ext = (sanitizedFilename as NSString).pathExtension
    let filePath = submissionsDir + "\(subID).\(ext)"
    try solutionNotebookData.write(to: URL(fileURLWithPath: filePath))

    let priorCount = try await APISubmission.query(on: req.db)
        .filter(\.$testSetupID == setupID)
        .filter(\.$kind == APISubmission.Kind.validation)
        .count()

    // Web callers attribute the submission to the session user; MCP callers
    // authenticate via a bearer token (no `Request.auth` APIUser) and pass the
    // resolved subject id explicitly.
    let resolvedSubmitterID: UUID?
    if let submitterUserID {
        resolvedSubmitterID = submitterUserID
    } else {
        resolvedSubmitterID = try req.auth.require(APIUser.self).id
    }
    let submission = APISubmission(
        id: subID,
        testSetupID: setupID,
        zipPath: filePath,
        attemptNumber: priorCount + 1,
        filename: sanitizedFilename,
        userID: resolvedSubmitterID,
        kind: APISubmission.Kind.validation
    )

    // Resolve personalization and write the grading sidecar BEFORE the
    // submission is saved. Saving makes it `pending` — a polling worker can
    // claim and download it immediately — so the substituted `.grading` sidecar
    // and the cached `materializationJSON` MUST already be in place, or the
    // worker races in and grades the un-substituted template. The returned
    // token is the only way to persist the row, so the ordering is enforced by
    // the types, not by this comment. (This resolves personalization once, at
    // enqueue — an instructor save, which is latency-tolerant — so the worker
    // poll + download paths never run the personalization evaluator.)
    let materialized = await materializeValidationGrading(
        submission: submission,
        setupID: setupID,
        templateNotebookData: solutionNotebookData,
        testSetupsDirectory: req.application.testSetupsDirectory,
        on: req.db)

    try await materialized.saveClaimable(on: req.db)

    // Keep the server-side `shared/{setupID}/solution.py` in lockstep with the
    // reference solution, so a Global Input expression can compute an expected
    // value as `solution.<fn>(...)` — one source of truth — instead of a
    // hand-maintained answer key that can silently drift from the solution.
    // This file lives ONLY in the shared directory (never the test-setup zip),
    // so it never reaches the worker, the browser, or a student support-file
    // download — mirroring how `solution.ipynb` is kept out of every
    // student-facing path. Best-effort: failure just leaves `import solution`
    // unavailable (the prior behaviour) and never blocks the save.
    let sharedDir = req.application.testSetupsDirectory + "shared/\(setupID)/"
    SolutionNotebookExtractor.writeSolutionPy(
        notebookData: solutionNotebookData,
        sharedDirectory: sharedDir,
        overwrite: true)

    return subID
}

/// Proof that `materializeValidationGrading` ran for a validation submission:
/// the grading sidecar and the in-memory `materializationJSON` cache are in
/// place, so persisting the row — which flips it to `pending` and makes it
/// claimable by a polling worker — is now safe.  Only constructible by
/// `materializeValidationGrading`, so "materialize before save" is a compile-
/// time guarantee at the enqueue site rather than a comment.
struct MaterializedValidationSubmission {
    fileprivate let submission: APISubmission

    /// The single save that makes the row claimable.
    func saveClaimable(on db: any Database) async throws {
        try await submission.save(on: db)
    }
}

/// Resolve a validation submission's personalization ONCE, so the worker poll +
/// download paths never run `python3` (which the runner times out against on its
/// 5 s artifact download — the `#869` regression). Produces:
///
///   * `<submission.zipPath>.grading` — the solution notebook with `{{name}}`
///     placeholders substituted, written to disk. `WorkerArtifactRoutes`
///     streams it verbatim (pure I/O).
///   * `submission.materializationJSON` set **in memory** — the resolved `=`
///     expression value map plus the seed everything was resolved against.
///     `buildJobPayload` reads it instead of re-evaluating; the values become
///     `_ck_inputs.py`.
///
/// Call this BEFORE saving the submission — enforced by the return type: it
/// deliberately does NOT save, and the `MaterializedValidationSubmission`
/// token it returns is the only way to persist the row. The submission then
/// only becomes `pending` (claimable by a polling worker) once the sidecar and
/// cache are already in place; saving first would open a race where the worker
/// downloads the un-substituted template before this finishes.
///
/// The stored `zipPath` keeps its `{{...}}` template, so `get_solution`, the
/// editor, and re-validation by another user are unaffected.
///
/// Best-effort: never throws out. On any failure the submission is left
/// un-materialized — the download route then streams the template (grading
/// fails clearly, but the worker never times out), and `buildJobPayload` falls
/// back to live resolution.
func materializeValidationGrading(
    submission: APISubmission,
    setupID: String,
    templateNotebookData: Data,
    testSetupsDirectory: String,
    on db: any Database
) async -> MaterializedValidationSubmission {
    await resolveAndCacheValidationMaterialization(
        submission: submission,
        setupID: setupID,
        templateNotebookData: templateNotebookData,
        testSetupsDirectory: testSetupsDirectory,
        on: db)
    return MaterializedValidationSubmission(submission: submission)
}

/// Best-effort body of `materializeValidationGrading`: any early exit leaves
/// the submission un-materialized, which downstream paths handle (template
/// streamed verbatim, live fallback in `buildJobPayload`).
private func resolveAndCacheValidationMaterialization(
    submission: APISubmission,
    setupID: String,
    templateNotebookData: Data,
    testSetupsDirectory: String,
    on db: any Database
) async {
    do {
        guard let setup = try await APITestSetup.find(setupID, on: db),
            let manifestData = setup.manifest.data(using: .utf8),
            let manifest = try? ManifestCodec.decoder.decode(TestProperties.self, from: manifestData)
        else { return }

        // Non-personalized assignments: nothing to resolve or cache — the
        // download route streams the stored zip exactly as before.
        guard manifest.hasPersonalization else { return }

        // Resolve the per-(user, assignment) seed when we can. Literal variables
        // substitute without a seed; only `=` expressions need one.
        var seedHex: String?
        if let userID = submission.userID,
            let assignment = try await APIAssignment.query(on: db)
                .filter(\.$testSetupID == setupID)
                .first(),
            let assignmentID = assignment.id
        {
            seedHex = try? await AssignmentSeedStore.ensureSeed(
                userID: userID, assignmentID: assignmentID, on: db)
        }

        let supportDir = testSetupsDirectory + "shared/\(setupID)/"
        let resolution = await PersonalizationSubstitution.resolve(
            manifest: manifest, seedHex: seedHex, supportFilesDirectory: supportDir)

        // Expression-only value map (identical to `gradingInputs`) → _ck_inputs.py.
        let exprNames = Set(resolution.evaluatedExpressionNames)
        let inputs = resolution.substitutions.filter { exprNames.contains($0.key) }

        // Substitute the solution notebook once and write the grading sidecar.
        // Soft-fail substitution: the editor's save-time scan is the
        // authoritative gate for unknown placeholders.
        let filename = submission.filename ?? "solution.ipynb"
        if filename.lowercased().hasSuffix(".ipynb"),
            !resolution.substitutions.isEmpty,
            !templateNotebookData.isEmpty,
            let substituted = try? NotebookSubstitution.apply(
                notebookData: templateNotebookData,
                substitutions: resolution.substitutions,
                strict: false)
        {
            try? substituted.write(to: URL(fileURLWithPath: submission.zipPath + ".grading"))
        }

        let materialization = SubmissionMaterialization(
            key: manifestHash((seedHex ?? "") + "|" + setup.manifest),
            seedHex: seedHex,
            inputs: inputs)
        if let encoded = try? JSONEncoder().encode(materialization),
            let json = String(data: encoded, encoding: .utf8)
        {
            // Set in-memory only; the caller saves the submission exactly once,
            // AFTER this returns, so the row never becomes claimable before the
            // sidecar + cache are ready.
            submission.materializationJSON = json
        }
    } catch {
        // Best-effort: leave the submission un-materialized; the download route
        // falls back to streaming the template and buildJobPayload to live eval.
    }
}

/// Schedule a validation submission after a suite edit, best-effort.
/// Looks up the most recent solution notebook (either the currently linked
/// validation submission or the most recent validation for this setup) and
/// enqueues a fresh validation so the runner picks up the new manifest.
///
/// Debounced: if there's already a pending (unclaimed) validation for this
/// setup, we skip — the runner will pick that one up with the freshest
/// manifest (the test setup download URL carries a hash of manifest bytes,
/// so an in-flight submission still pulls the updated zip + manifest).
///
/// Pre-checks that a runner compatible with the assignment's
/// `AssignmentRequirement` is available before enqueueing.  If none is
/// available (and local-runner-autostart can't bring one up), the
/// validation is *not* enqueued and `validationStatus` is set to
/// `"no-runner"` so the assignments list shows a specific reason
/// instead of a perpetual "pending".  Pre-v0.4.130 the validation went
/// in regardless and silently sat in queue forever.
///
/// Errors are swallowed: this is a nice-to-have trigger from live-edit
/// endpoints and must not block the edit save.
///
/// `submitterUserID` attributes the validation submission. Web callers omit it
/// (the session user is resolved from `req.auth`); MCP callers MUST pass the
/// acting subject's id — bearer-authenticated requests carry no session
/// `APIUser`, so the `req.auth` fallback throws 401 and the validation is
/// silently never enqueued.
func scheduleValidationAfterSuiteEdit(
    req: Request,
    assignment: APIAssignment,
    submitterUserID: UUID? = nil
) async {
    do {
        let existingPending = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == assignment.testSetupID)
            .filter(\.$kind == APISubmission.Kind.validation)
            .filter(\.$status == SubmissionStatus.pending.rawValue)
            .first()
        if existingPending != nil { return }

        guard let solution = try await loadExistingSolution(req: req, assignment: assignment)
        else { return }

        let requirementSpec = try await loadAssignmentRequirementSpec(
            assignment: assignment,
            on: req.db
        )
        let hasRunner = try await ensureCompatibleValidationRunnerAvailability(
            req: req,
            requirements: requirementSpec
        )
        guard hasRunner else {
            assignment.validationStatus = "no-runner"
            try await assignment.save(on: req.db)
            return
        }

        let subID = try await enqueueRunnerValidationSubmission(
            req: req,
            setupID: assignment.testSetupID,
            solutionNotebookData: solution.data,
            filename: solution.filename,
            submitterUserID: submitterUserID
        )
        assignment.validationSubmissionID = subID
        assignment.validationStatus = "pending"
        try await assignment.save(on: req.db)
    } catch {
        req.logger.warning("scheduleValidationAfterSuiteEdit: \(error)")
    }
}

/// Re-queues every student submission for a test setup so the worker
/// regrades them against the current manifest.  Introduced in v0.4.93 to
/// close the loop on assignment revisions: after an instructor fixes a
/// bug in the test suite (or edits a pattern family), every prior
/// submission gets a fresh result computed against the new grading logic.
///
/// Scope decisions (from v0.4.93 design):
/// - **Every submission**, not just the latest per student — the caller's
///   call.  At ~1s/submission on two runners, 150 students × a few
///   attempts = ~10 min total, acceptable queue latency for this use.
/// - **Excludes `kind = .validation`.**  The instructor's solution
///   notebook re-validates via `scheduleValidationAfterSuiteEdit`, which
///   enqueues a fresh validation row; bumping the old one would
///   double-enqueue.
/// - **Browser-graded submissions get handled automatically** — the
///   v0.4.56 worker backstop already treats any pending submission as a
///   candidate, running the generated `.py` scripts natively via
///   `python3`.  Flipping `status = "pending"` is enough.
/// - **Idempotent against in-flight retests.**  Submissions already in
///   `pending` / `assigned` are skipped unless `force = true`, so
///   rapid-fire saves (or the manual "Retest all" button after an
///   auto-retest already fired) don't double-queue the same row.
/// - **Does not mutate `lastRetestedManifestHash` on the setup** — the
///   caller owns that bookkeeping (the helper can be invoked for a
///   setup-hash-unchanged save via the explicit button).
///
/// Returns the number of submissions whose status was flipped to pending.
@discardableResult
func retestAllSubmissionsForSetup(
    setupID: String,
    triggeredBy userID: UUID?,
    on db: Database,
    force: Bool = false
) async throws -> Int {
    try await bulkFlipStudentSubmissionsToPending(
        setupID: setupID,
        studentUserID: nil,
        triggeredBy: userID,
        force: force,
        on: db)
}

/// Re-queues matching `kind == .student` submissions for one setup (optionally
/// scoped to a single student) in **one** `UPDATE` rather than a save per row.
///
/// A deadline-day "Retest all" can touch tens of thousands of submissions; the
/// previous load-all-then-save-each loop blocked the instructor's request and
/// left a half-retested set on mid-failure. The bulk update is self-atomic and
/// constant in round-trips. The returned count is measured with the identical
/// predicate just before the write so it matches what the UPDATE affects (a
/// concurrent insert between the two is benign — it's a freshly-pending row
/// either way).
@discardableResult
func bulkFlipStudentSubmissionsToPending(
    setupID: String,
    studentUserID: UUID?,
    triggeredBy userID: UUID?,
    force: Bool,
    on db: Database
) async throws -> Int {
    let now = Date()

    func scoped() -> QueryBuilder<APISubmission> {
        let query = APISubmission.query(on: db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$kind == APISubmission.Kind.student)
        if let studentUserID {
            _ = query.filter(\.$userID == studentUserID)
        }
        // Skip rows already in flight unless explicitly forced, mirroring
        // `flipSubmissionToPending`'s idempotency guard.
        if !force {
            _ = query.filter(\.$status !~ [SubmissionStatus.pending.rawValue, SubmissionStatus.assigned.rawValue])
        }
        return query
    }

    let touched = try await scoped().count()
    guard touched > 0 else { return 0 }

    try await scoped()
        .set(\.$status, to: SubmissionStatus.pending.rawValue)
        .set(\.$workerID, to: nil)
        .set(\.$assignedAt, to: nil)
        .set(\.$retestedAt, to: now)
        .set(\.$retestedByUserID, to: userID)
        .update()

    return touched
}

/// Re-queues every student submission on `setup` for regrade **iff** the
/// manifest changed since the last regrade — the shared core of the automatic
/// "Retest all" behavior, used by both the web suite editor (`PUT /suite`) and
/// the MCP content-edit tools so the human and agent paths stay in lockstep.
///
/// Compares `manifestHash(setup.manifest)` (the post-edit manifest, which
/// `applyPatternFamilies` has already written onto `setup`) against
/// `setup.lastRetestedManifestHash`: on a change it retests (`force: false`, so
/// rows already pending/assigned are skipped) and bumps the stored hash so a
/// later cosmetic save won't duplicate the work; on no change it's a no-op.
/// Returns the number of submissions re-queued (0 when unchanged). Throws on a
/// DB failure — callers that must not fail the edit wrap it best-effort.
@discardableResult
func retestSubmissionsIfManifestChanged(
    setup: APITestSetup, triggeredBy userID: UUID?, on db: any Database
) async throws -> Int {
    let currentHash = manifestHash(setup.manifest)
    guard setup.lastRetestedManifestHash != currentHash else { return 0 }
    let count = try await retestAllSubmissionsForSetup(
        setupID: try setup.requireID(),
        triggeredBy: userID,
        on: db,
        force: false)
    setup.lastRetestedManifestHash = currentHash
    try await setup.save(on: db)
    return count
}

/// Retests every `kind == .student` submission on `setupID` for one user
/// only (used by the per-student × per-assignment Retest button).  Skips
/// `kind == .validation` and other students' submissions.  Honours the
/// same "already in flight" skip rule as `retestAllSubmissionsForSetup`
/// unless `force = true`.
///
/// Returns the number of submissions whose status was flipped to pending.
@discardableResult
func retestStudentSubmissionsForSetup(
    setupID: String,
    studentUserID: UUID,
    triggeredBy userID: UUID?,
    on db: Database,
    force: Bool = false
) async throws -> Int {
    try await bulkFlipStudentSubmissionsToPending(
        setupID: setupID,
        studentUserID: studentUserID,
        triggeredBy: userID,
        force: force,
        on: db)
}

/// Flips one submission back to `pending` for the worker queue.  Returns
/// true when the row was actually mutated; false when `force == false`
/// and the row was already in flight (`pending`/`assigned`).  Stamps
/// `retested_at` and `retested_by_user_id` for traceability.
@discardableResult
func flipSubmissionToPending(
    _ submission: APISubmission,
    triggeredBy userID: UUID?,
    on db: Database,
    force: Bool = false,
    now: Date = Date()
) async throws -> Bool {
    if !force && (submission.statusValue == .pending || submission.statusValue == .assigned) {
        return false
    }
    submission.setStatus(.pending)
    submission.workerID = nil
    submission.assignedAt = nil
    submission.retestedAt = now
    submission.retestedByUserID = userID
    try await submission.save(on: db)
    return true
}

func waitForRunnerValidation(
    req: Request,
    submissionID: String,
    timeoutSeconds: TimeInterval = 20
) async throws -> RunnerValidationOutcome {
    let started = Date()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    while Date().timeIntervalSince(started) < timeoutSeconds {
        guard let submission = try await APISubmission.find(submissionID, on: req.db),
            submission.kind == APISubmission.Kind.validation
        else {
            throw WebAssignmentError.notFound(resource: "Validation submission")
        }

        if submission.statusValue == .complete || submission.statusValue == .failed {
            guard
                let result = try await APIResult.query(on: req.db)
                    .filter(\.$submissionID == submissionID)
                    .sort(\.$receivedAt, .descending)
                    .first(),
                let collectionJSON = try await result.loadCollectionJSON(on: req.db)
            else {
                return .failed(summary: "no result payload")
            }

            let collection = try decoder.decode(
                TestOutcomeCollection.self, from: Data(collectionJSON.utf8))
            let summary = "\(collection.passCount)/\(collection.totalTests) passed"
            let passed =
                collection.buildStatus == .passed && collection.failCount == 0 && collection.errorCount == 0
                && collection.timeoutCount == 0
            return passed ? .passed(summary: summary) : .failed(summary: summary)
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    return .timedOut
}

func ensureValidationRunnerAvailability(req: Request) async {
    let enabled = await req.application.localRunnerAutoStartStore.isEnabled()
    guard enabled else { return }

    let hasRecentRunner = await req.application.workerActivityStore.hasRecentActivity(within: 20)
    guard !hasRecentRunner else { return }

    await req.application.localRunnerManager.ensureRunning(app: req.application, logger: req.logger)
    try? await Task.sleep(nanoseconds: 1_000_000_000)
}

func hasCompatibleValidationRunner(
    req: Request,
    requirements: AssignmentRequirementSpec?,
    activeWindowSeconds: TimeInterval = 20
) async throws -> Bool {
    try await req.application.runnerProfiles.refreshActiveFlags(
        activeWindowSeconds: activeWindowSeconds,
        on: req.db
    )

    let profiles = try await RunnerProfile.query(on: req.db)
        .filter(\.$isActive == true)
        .all()
    let matcher = CompatibilityMatcher()

    return profiles.contains { profile in
        matcher.evaluate(
            runnerProfile: profile.capabilityProfile,
            requirements: requirements
        ).isCompatible
    }
}

func ensureCompatibleValidationRunnerAvailability(
    req: Request,
    requirements: AssignmentRequirementSpec?,
    activeWindowSeconds: TimeInterval = 20,
    attempts: Int = 3
) async throws -> Bool {
    if try await hasCompatibleValidationRunner(
        req: req,
        requirements: requirements,
        activeWindowSeconds: activeWindowSeconds
    ) {
        return true
    }

    let enabled = await req.application.localRunnerAutoStartStore.isEnabled()
    guard enabled else { return false }

    await req.application.localRunnerManager.ensureRunning(app: req.application, logger: req.logger)

    for attempt in 0..<attempts {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if try await hasCompatibleValidationRunner(
            req: req,
            requirements: requirements,
            activeWindowSeconds: activeWindowSeconds
        ) {
            return true
        }

        if attempt + 1 < attempts {
            await req.application.localRunnerManager.ensureRunning(app: req.application, logger: req.logger)
        }
    }

    return false
}
