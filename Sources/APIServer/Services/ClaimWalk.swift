// APIServer/Services/ClaimWalk.swift
//
// One runner poll's claim walk over the candidates `ClaimCandidateLoader`
// loads (WorkerClaimEvaluation.swift drives it). Takes a database, the
// application and a logger through `ClaimEvaluator`, never a `Request`.

import Core
import Foundation
import Vapor

/// A candidate that was skipped because the runner's profile didn't match the
/// assignment's requirements.  We keep the *first* one we see so that, when no
/// candidate is claimable, we can emit a single "no compatible runner
/// available" diagnostic instead of one per scanned candidate.
private struct BlockedCandidate {
    let submission: APISubmission
    let assignmentID: UUID?
    let requirements: AssignmentRequirementSpec?
    let result: CompatibilityResult
}

/// The state of one claim walk, which may span several candidate groups
/// (`ClaimCandidateLoader`): the first blocked candidate, for the single
/// "no compatible runner available" diagnostic, and the per-assignment
/// answers that do not change within one poll.
struct ClaimWalk {
    let body: WorkerActivityPayload
    let runnerProfile: RunnerCapabilityProfile?
    let evaluator: ClaimEvaluator

    private var blockedCandidate: BlockedCandidate?

    /// The requirement row and compatibility decision, keyed by what
    /// `AssignmentRequirementService.loadRequirement` resolves the assignment
    /// from (`requirementKey`). Both are fixed for one setup within a poll,
    /// yet a runner that loses claim races, or that cannot grade the head of
    /// the queue, would otherwise reload them for every candidate.
    private var requirementsByKey: [String: LoadedAssignmentRequirement] = [:]
    private var compatibilityByKey: [String: CompatibilityResult] = [:]

    init(body: WorkerActivityPayload, runnerProfile: RunnerCapabilityProfile?, evaluator: ClaimEvaluator) {
        self.body = body
        self.runnerProfile = runnerProfile
        self.evaluator = evaluator
    }

    /// Checks each candidate in order against the runner's capability
    /// profile and claims the first compatible one that is still pending, or
    /// returns nil when none is.
    mutating func claimFirst(
        in candidates: [ClaimCandidate],
        claim: (String) async throws -> APISubmission?
    ) async throws -> ClaimedJob? {
        for (submission, setup, manifest) in candidates {
            // A job that asks for another runner waits for it, up to the
            // fallback time. It is not a blocked candidate: this runner could
            // grade it, it only goes second.
            guard
                RunnerTargetGate.allows(
                    targetRunnerID: submission.targetRunnerID, queuedAt: submission.submittedAt,
                    runnerID: body.workerID, now: Date())
            else { continue }

            let key = Self.requirementKey(of: submission)
            let loadedRequirements: LoadedAssignmentRequirement
            if let cached = requirementsByKey[key] {
                loadedRequirements = cached
            } else {
                loadedRequirements = try await evaluator.assignmentRequirements.loadRequirement(
                    for: submission, on: evaluator.db)
                requirementsByKey[key] = loadedRequirements
            }
            let requirementSpec = loadedRequirements.requirement?.requirementSpec

            evaluator.application.diagnostics.recordAssignmentRequirementsLoaded(
                submission: submission,
                assignmentID: loadedRequirements.assignmentID,
                requirements: requirementSpec,
                logger: evaluator.logger
            )

            // One decision, shared with the unclaimable-jobs health rule
            // (`claimCompatibility`): the capability requirements, the version
            // gates (deployment floor and the manifest's `minimumRunnerVersion`),
            // the implicit language gate and the class-activity gate. The
            // language gate needs no authoring step: the manifest already knows
            // what language the assignment is in and the runner already
            // advertises what it has, so a runner that cannot grade this
            // assignment leaves it for one that can instead of failing it.
            let compatibilityResult: CompatibilityResult
            if let cached = compatibilityByKey[key] {
                compatibilityResult = cached
            } else {
                compatibilityResult = claimCompatibility(
                    runnerVersion: body.runnerVersion,
                    runnerProfile: runnerProfile,
                    manifest: manifest,
                    requirements: requirementSpec,
                    matcher: evaluator.compatibilityMatcher
                )
                compatibilityByKey[key] = compatibilityResult
            }
            await evaluator.application.diagnostics.recordCompatibilityDecision(
                submission: submission,
                assignmentID: loadedRequirements.assignmentID,
                runnerID: body.workerID,
                requirements: requirementSpec,
                result: compatibilityResult,
                logger: evaluator.logger
            )

            guard compatibilityResult.isCompatible else {
                if blockedCandidate == nil {
                    blockedCandidate = BlockedCandidate(
                        submission: submission,
                        assignmentID: loadedRequirements.assignmentID,
                        requirements: requirementSpec,
                        result: compatibilityResult
                    )
                }
                continue
            }

            guard let submissionID = submission.id,
                let claimed = try await claim(submissionID)
            else {
                // Lost the claim race (or a malformed row) — the next
                // candidate may still be ours.
                continue
            }

            if RunnerTargetGate.isFallback(targetRunnerID: claimed.targetRunnerID, runnerID: body.workerID) {
                evaluator.logger.info(
                    "targeted_job_fallback",
                    metadata: [
                        "submission_id": .string(submissionID),
                        "target_runner_id": .string(claimed.targetRunnerID ?? ""),
                        "runner_id": .string(body.workerID),
                    ])
            }

            return ClaimedJob(
                submission: claimed,
                setup: setup,
                manifest: manifest,
                assignmentID: loadedRequirements.assignmentID,
                requirementSpec: requirementSpec
            )
        }
        return nil
    }

    /// Ends a walk that claimed nothing: emits one "no compatible runner
    /// available" diagnostic for the first blocked candidate, if any.
    func finish() async {
        guard let blockedCandidate else { return }
        await evaluator.application.diagnostics.recordNoCompatibleRunnerAvailable(
            submission: blockedCandidate.submission,
            assignmentID: blockedCandidate.assignmentID,
            runnerID: body.workerID,
            requirements: blockedCandidate.requirements,
            result: blockedCandidate.result,
            logger: evaluator.logger
        )
    }

    /// What `loadRequirement` resolves the assignment from: the validation
    /// submission's own id for a solution run, the test setup otherwise. The
    /// manifest is the setup's in both cases, so the key also fixes the
    /// compatibility decision.
    private static func requirementKey(of submission: APISubmission) -> String {
        if submission.kind == APISubmission.Kind.validation, let submissionID = submission.id {
            return "validation:\(submissionID)"
        }
        return "setup:\(submission.testSetupID)"
    }
}
