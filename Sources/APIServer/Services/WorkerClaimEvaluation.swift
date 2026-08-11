// APIServer/Services/WorkerClaimEvaluation.swift
//
// The claim walk: load the ordered candidate list, decide per candidate
// whether this runner may grade it, and claim the first one that it may.
//
// Split out of WorkerJobRoutes.swift (#1253).  These types were file-private
// there, so the routes file was the only thing that could see them even though
// none of them is about HTTP.  The one genuine coupling was the claim step
// itself, which lives on the route collection because it needs the request;
// it is injected as a closure rather than dragging the walk back into the
// routes file.

import Core
import Fluent
import Foundation
import Vapor

/// Output of `claimNextEligibleJob` — the submission + setup pair that was
/// atomically claimed inside the transaction, plus the assignment context
/// needed for downstream diagnostics and `Job` payload construction.
struct ClaimedJob {
    let submission: APISubmission
    let setup: APITestSetup
    let manifest: TestProperties
    let assignmentID: UUID?
    let requirementSpec: AssignmentRequirementSpec?
}

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

/// Loads the ordered list of claim candidates (plain reads, outside the
/// serialized claim section — the compare-and-set claim re-checks pending).
/// Fresh student work (retestedAt == nil) is claimed before any retest
/// (retestedAt != nil), so a manifest-revision sweep can't starve students who
/// are actively submitting (#427). Within each group, oldest submittedAt wins.
/// Validation submissions are always worker-mode (instructors validate via worker)
/// and are appended after student work.
func collectClaimCandidates(
    on db: Database
) async throws -> [(APISubmission, APITestSetup, TestProperties)] {
    // Cap the scan: a poll claims exactly one job, so walking the entire
    // pending queue (potentially tens of thousands of rows after a retest
    // fan-out) inside the globally-serialized claim transaction collapsed
    // claim throughput exactly when the queue was deepest (June 2026 audit,
    // P1.3). The cap only matters when the first `claimCandidateScanLimit`
    // candidates are all requirement-incompatible with this runner — the next
    // poll retries, and most assignments carry no runner requirements at all.
    //
    // Fresh student work (retestedAt == nil) keeps absolute priority over
    // retests (#427) by querying the two groups separately — which also
    // replaces the old full-scan + in-memory re-sort.
    let claimCandidateScanLimit = 50
    var studentSubmissions = try await APISubmission.query(on: db)
        .filter(\.$status == SubmissionStatus.pending.rawValue)
        .filter(\.$kind == APISubmission.Kind.student)
        .filter(\.$retestedAt == nil)
        .sort(\.$submittedAt, .ascending)
        .limit(claimCandidateScanLimit)
        .all()
    if studentSubmissions.count < claimCandidateScanLimit {
        studentSubmissions += try await APISubmission.query(on: db)
            .filter(\.$status == SubmissionStatus.pending.rawValue)
            .filter(\.$kind == APISubmission.Kind.student)
            .filter(\.$retestedAt != nil)
            .sort(\.$submittedAt, .ascending)
            .limit(claimCandidateScanLimit - studentSubmissions.count)
            .all()
    }

    // Many pending submissions often target the same test setup (e.g. a class
    // submitting to one assignment before a deadline). Resolve each setup +
    // decoded manifest once and reuse it, rather than re-querying the row and
    // re-decoding the identical manifest JSON for every candidate.
    var resolvedBySetupID: [String: (APITestSetup, TestProperties)] = [:]
    var candidates: [(APISubmission, APITestSetup, TestProperties)] = []

    for candidate in studentSubmissions {
        if let cached = resolvedBySetupID[candidate.testSetupID] {
            candidates.append((candidate, cached.0, cached.1))
            continue
        }
        guard let setup = try await APITestSetup.find(candidate.testSetupID, on: db) else { continue }
        guard let manifest = decodeManifest(from: Data(setup.manifest.utf8)) else { continue }
        resolvedBySetupID[candidate.testSetupID] = (setup, manifest)
        // Accept both worker-mode and browser-mode pending submissions.
        // Browser-mode submissions become pending when the client-side runner
        // fails or freezes (the `browser-failover` endpoint enqueues them) or
        // when an instructor retests; the worker serves as a backstop that runs
        // the .py test scripts natively via python3.
        candidates.append((candidate, setup, manifest))
    }

    let pendingValidation = try await APISubmission.query(on: db)
        .filter(\.$status == SubmissionStatus.pending.rawValue)
        .filter(\.$kind == APISubmission.Kind.validation)
        .sort(\.$submittedAt, .ascending)
        .limit(claimCandidateScanLimit)
        .all()

    for validation in pendingValidation {
        if let cached = resolvedBySetupID[validation.testSetupID] {
            candidates.append((validation, cached.0, cached.1))
            continue
        }
        guard let valSetup = try await APITestSetup.find(validation.testSetupID, on: db) else {
            throw WorkerJobError.testSetupNotFound(id: validation.testSetupID)
        }
        let valManifest = try ManifestCodec.decoder.decode(
            TestProperties.self, from: Data(valSetup.manifest.utf8))
        resolvedBySetupID[validation.testSetupID] = (valSetup, valManifest)
        candidates.append((validation, valSetup, valManifest))
    }

    return candidates
}

/// Walks the ordered candidate list, checks each against the runner's
/// capability profile, and atomically claims the first compatible one that is
/// still pending.  All evaluation (requirement queries, compatibility
/// matching, diagnostics) happens outside the serialized claim section; only
/// the compare-and-set claim itself is serialized.  A candidate that another
/// runner claimed since the scan fails its CAS and the walk continues.  When
/// no candidate is claimable, emits a single "no compatible runner available"
/// diagnostic for the first blocked candidate we saw and returns nil.
/// ClaimEvaluator bundles the per-claim collaborators that don't change
/// between candidates, so the evaluation helper stays under the
/// parameter-count cap.
struct ClaimEvaluator {
    let assignmentRequirements: AssignmentRequirementService
    let compatibilityMatcher: CompatibilityMatcher
}

func evaluateAndClaimCandidate(
    candidates: [(APISubmission, APITestSetup, TestProperties)],
    req: Request,
    body: WorkerActivityPayload,
    runnerProfile: RunnerCapabilityProfile?,
    evaluator: ClaimEvaluator,
    /// Claims the candidate with this id, or returns nil if another runner
    /// won the race.  Injected because the claim needs the route
    /// collection's request-scoped database handle.
    claim: (String) async throws -> APISubmission?
) async throws -> ClaimedJob? {
    var blockedCandidate: BlockedCandidate?

    for (submission, setup, manifest) in candidates {
        let loadedRequirements = try await evaluator.assignmentRequirements.loadRequirement(
            for: submission, on: req.db)
        let requirementSpec = loadedRequirements.requirement?.requirementSpec

        req.application.diagnostics.recordAssignmentRequirementsLoaded(
            submission: submission,
            assignmentID: loadedRequirements.assignmentID,
            requirements: requirementSpec,
            logger: req.logger
        )

        let capabilityResult = evaluator.compatibilityMatcher.evaluate(
            runnerProfile: runnerProfile,
            requirements: requirementSpec
        )
        // Fold the manifest's optional `minimumRunnerVersion` gate and the
        // implicit language gate into the same verdict so either block rides
        // the existing diagnostics / guard / blocked-candidate path.  Use
        // the *merged* result below, not `capabilityResult`, or the
        // diagnostics would report "compatible" while the job is actually
        // blocked.
        //
        // The language gate needs no authoring step: the manifest already
        // knows what language the assignment is in and the runner already
        // advertises what it has, so a runner that cannot grade this
        // assignment leaves it for one that can instead of failing it.
        let versionResult = RunnerVersionGate.evaluate(
            runnerVersion: body.runnerVersion,
            minimumRunnerVersion: manifest.minimumRunnerVersion
        )
        let languageResult = RunnerLanguageGate.evaluate(
            runnerProfile: runnerProfile,
            manifest: manifest
        )
        let compatibilityResult = RunnerVersionGate.combine(
            RunnerVersionGate.combine(capabilityResult, versionResult),
            languageResult
        )
        await req.application.diagnostics.recordCompatibilityDecision(
            submission: submission,
            assignmentID: loadedRequirements.assignmentID,
            runnerID: body.workerID,
            requirements: requirementSpec,
            result: compatibilityResult,
            logger: req.logger
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

        return ClaimedJob(
            submission: claimed,
            setup: setup,
            manifest: manifest,
            assignmentID: loadedRequirements.assignmentID,
            requirementSpec: requirementSpec
        )
    }

    if let blockedCandidate {
        await req.application.diagnostics.recordNoCompatibleRunnerAvailable(
            submission: blockedCandidate.submission,
            assignmentID: blockedCandidate.assignmentID,
            runnerID: body.workerID,
            requirements: blockedCandidate.requirements,
            result: blockedCandidate.result,
            logger: req.logger
        )
    }
    return nil
}
