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
    filename: String = "solution.ipynb"
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

    let user = try req.auth.require(APIUser.self)
    let submission = APISubmission(
        id: subID,
        testSetupID: setupID,
        zipPath: filePath,
        attemptNumber: priorCount + 1,
        filename: sanitizedFilename,
        userID: user.id,
        kind: APISubmission.Kind.validation
    )
    try await submission.save(on: req.db)
    return subID
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
func scheduleValidationAfterSuiteEdit(
    req: Request,
    assignment: APIAssignment
) async {
    do {
        let existingPending = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == assignment.testSetupID)
            .filter(\.$kind == APISubmission.Kind.validation)
            .filter(\.$status == "pending")
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
            filename: solution.filename
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
    let submissions = try await APISubmission.query(on: db)
        .filter(\.$testSetupID == setupID)
        .filter(\.$kind == APISubmission.Kind.student)
        .all()

    let now = Date()
    var touched = 0
    for submission in submissions {
        if try await flipSubmissionToPending(
            submission,
            triggeredBy: userID,
            on: db,
            force: force,
            now: now
        ) {
            touched += 1
        }
    }
    return touched
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
    let submissions = try await APISubmission.query(on: db)
        .filter(\.$testSetupID == setupID)
        .filter(\.$userID == studentUserID)
        .filter(\.$kind == APISubmission.Kind.student)
        .all()

    let now = Date()
    var touched = 0
    for submission in submissions {
        if try await flipSubmissionToPending(
            submission,
            triggeredBy: userID,
            on: db,
            force: force,
            now: now
        ) {
            touched += 1
        }
    }
    return touched
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
    if !force && (submission.status == "pending" || submission.status == "assigned") {
        return false
    }
    submission.status = "pending"
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

        if submission.status == "complete" || submission.status == "failed" {
            guard
                let result = try await APIResult.query(on: req.db)
                    .filter(\.$submissionID == submissionID)
                    .sort(\.$receivedAt, .descending)
                    .first(),
                let data = result.collectionJSON.data(using: .utf8)
            else {
                return .failed(summary: "no result payload")
            }

            let collection = try decoder.decode(TestOutcomeCollection.self, from: data)
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
