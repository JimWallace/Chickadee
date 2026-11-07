// APIServer/Services/WorkerClaimEvaluation.swift
//
// The claim walk: load the ordered candidate list, decide per candidate
// whether this runner may grade it, and claim the first one that it may.
//
// Split out of WorkerJobRoutes.swift (#1253).  These types were file-private
// there, so the routes file was the only thing that could see them even though
// none of them is about HTTP.  The one genuine coupling was the claim step
// itself; it is injected as a closure (`WorkerJobClaim.claimSubmission`,
// moved out of the routes file in #2774). The walk itself takes a database,
// the application and a logger through `ClaimEvaluator`, never a `Request`
// (#1732, #2145).

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

/// Loads the whole ordered list of claim candidates, every group in priority
/// order. The claim walk itself loads the groups lazily
/// (`WorkerJobClaim.claimNextEligibleJob`); this eager form is for callers
/// that inspect the full order.
func collectClaimCandidates(on db: any Database) async throws -> [ClaimCandidate] {
    var loader = ClaimCandidateLoader(db: db)
    var candidates: [ClaimCandidate] = []
    for group in ClaimCandidateGroup.allCases {
        candidates += try await loader.load(group)
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
    let db: any Database
    let application: Application
    let logger: Logger
}

func evaluateAndClaimCandidate(
    candidates: [ClaimCandidate],
    body: WorkerActivityPayload,
    runnerProfile: RunnerCapabilityProfile?,
    evaluator: ClaimEvaluator,
    /// Claims the candidate with this id, or returns nil if another runner
    /// won the race.  Injected because the claim needs the route
    /// collection's request-scoped database handle.
    claim: (String) async throws -> APISubmission?
) async throws -> ClaimedJob? {
    var walk = ClaimWalk(body: body, runnerProfile: runnerProfile, evaluator: evaluator)
    if let claimed = try await walk.claimFirst(in: candidates, claim: claim) {
        return claimed
    }
    await walk.finish()
    return nil
}
