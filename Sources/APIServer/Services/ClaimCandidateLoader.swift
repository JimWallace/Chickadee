// APIServer/Services/ClaimCandidateLoader.swift
//
// The runner claim walk's candidates, loaded one priority group at a time
// (WorkerClaimEvaluation.swift drives the walk). Takes a database, never a
// `Request`.

import Core
import Fluent
import Foundation

/// One claim candidate: the pending submission, its setup and the setup's
/// decoded manifest.
typealias ClaimCandidate = (APISubmission, APITestSetup, TestProperties)

/// The candidate groups, in claim priority order. Fresh student work
/// (retestedAt == nil) is claimed before any retest (retestedAt != nil), so a
/// manifest-revision sweep can't starve students who are actively submitting
/// (#427). Tournament matches (docs/class-activities.md) are a live-session
/// action, so they follow student work and precede validation. A starter run
/// goes after every solution run: the solution run's verdict gates opening,
/// and the starter run only warns. Validation submissions are always
/// worker-mode (instructors validate via worker).
///
/// The class corpus run (docs/collaborative-class-assignments.md) and a class
/// composite's reference jobs (docs/class-composite.md) go LAST, behind
/// everything a human is waiting on. Nobody is watching them land: they feed
/// a progress bar or a backdrop, and a deadline spike is exactly when a
/// student's job must not queue behind them. Among these, a composite spare
/// comes first: it is the one a student waits for, though it still waits
/// behind every student job. Then the corpus run, because one composite can
/// queue more reference jobs than the scan limit.
enum ClaimCandidateGroup: CaseIterable {
    case freshStudent
    case retestStudent
    case tournamentMatch
    case solutionValidation
    case starterValidation
    case compositeSpare
    case classAggregate
    case compositeReference
}

/// Loads the claim candidates one group at a time (plain reads, outside the
/// serialized claim section — the compare-and-set claim re-checks pending).
/// Within each group, oldest submittedAt wins.
///
/// The claim walk loads a group only when every earlier group had nothing
/// this runner could claim. During a deadline backlog the first fresh student
/// job is nearly always the one claimed, so a poll reads one group, not all
/// eight, and resolves only that group's setups.
struct ClaimCandidateLoader {
    /// Cap the scan: a poll claims exactly one job, so walking the entire
    /// pending queue (potentially tens of thousands of rows after a retest
    /// fan-out) inside the globally-serialized claim transaction collapsed
    /// claim throughput exactly when the queue was deepest (June 2026 audit,
    /// P1.3). The cap only matters when the first `scanLimit` candidates are
    /// all requirement-incompatible with this runner — the next poll retries,
    /// and most assignments carry no runner requirements at all.
    ///
    /// Fresh student work and retests share one cap: retests fill only what
    /// fresh work leaves, which replaces the old full-scan + in-memory
    /// re-sort.
    static let scanLimit = 50

    let db: any Database

    /// Many pending submissions often target the same test setup (e.g. a
    /// class submitting to one assignment before a deadline). Resolve each
    /// setup + decoded manifest once and reuse it, rather than re-querying the
    /// row and re-decoding the identical manifest JSON for every candidate.
    private var resolvedBySetupID: [String: (APITestSetup, TestProperties)] = [:]
    private var freshStudentCount = 0

    init(db: any Database) {
        self.db = db
    }

    /// The candidates of `group`, oldest first. Load the groups in
    /// `ClaimCandidateGroup.allCases` order: the retest group fills only the
    /// part of the scan cap that the fresh group left.
    mutating func load(_ group: ClaimCandidateGroup) async throws -> [ClaimCandidate] {
        switch group {
        case .freshStudent:
            let fresh = try await pending(kind: APISubmission.Kind.student, retested: false, limit: Self.scanLimit)
            freshStudentCount = fresh.count
            // Accept both worker-mode and browser-mode pending submissions.
            // Browser-mode submissions become pending when the client-side
            // runner fails or freezes (the `browser-failover` endpoint
            // enqueues them) or when an instructor retests; the worker serves
            // as a backstop that runs the .py test scripts natively via
            // python3.
            return try await resolveLeniently(fresh)
        case .retestStudent:
            let remaining = Self.scanLimit - freshStudentCount
            guard remaining > 0 else { return [] }
            return try await resolveLeniently(
                pending(kind: APISubmission.Kind.student, retested: true, limit: remaining))
        case .tournamentMatch:
            return try await resolveLeniently(pending(kind: APISubmission.Kind.tournamentMatch))
        case .solutionValidation:
            return try await resolveStrictly(pending(kind: APISubmission.Kind.validation))
        case .starterValidation:
            return try await resolveStrictly(pending(kind: APISubmission.Kind.starterValidation))
        case .compositeSpare:
            return try await resolveLeniently(pending(kind: APISubmission.Kind.compositeSpare))
        case .classAggregate:
            return try await resolveLeniently(pending(kind: APISubmission.Kind.classAggregate))
        case .compositeReference:
            return try await resolveLeniently(pending(kind: APISubmission.Kind.compositeReference))
        }
    }

    /// The oldest pending submissions of `kind`. `retested` splits student
    /// work into fresh (`false`) and retest (`true`) passes; nil reads both.
    ///
    /// The two student passes read only pending rows, whatever the planner
    /// statistics say. The fresh pass sorts on `retested_at` first. Every row it returns has a NULL `retested_at`, so the order is
    /// exactly `submitted_at`, but only `idx_submissions_claim_priority`
    /// returns that order, from the range that holds the fresh pending rows;
    /// any other plan must sort every row it reads. Sorted on `submitted_at`
    /// alone, statistics that showed a large pending share made the planner
    /// walk `idx_submissions_submitted_at` from the oldest row and filter out
    /// every completed submission (36 ms per poll on a 225k-row table). The
    /// retest pass reads `idx_submissions_pending_retest_submitted_at`
    /// (CreatePendingRetestIndex.swift).
    private func pending(
        kind: String, retested: Bool? = nil, limit: Int? = nil
    ) async throws -> [APISubmission] {
        var query = APISubmission.query(on: db)
            .filter(\.$status == SubmissionStatus.pending.rawValue)
            .filter(\.$kind == kind)
        switch retested {
        case .some(false): query = query.filter(\.$retestedAt == nil).sort(\.$retestedAt, .ascending)
        case .some(true): query = query.filter(\.$retestedAt != nil)
        case nil: break
        }
        return try await query.sort(\.$submittedAt, .ascending).limit(limit ?? Self.scanLimit).all()
    }

    /// Pairs each submission with its setup and manifest, skipping one whose
    /// setup is gone or whose manifest does not decode.
    private mutating func resolveLeniently(_ submissions: [APISubmission]) async throws -> [ClaimCandidate] {
        var candidates: [ClaimCandidate] = []
        candidates.reserveCapacity(submissions.count)
        for submission in submissions {
            if let cached = resolvedBySetupID[submission.testSetupID] {
                candidates.append((submission, cached.0, cached.1))
                continue
            }
            guard let setup = try await APITestSetup.find(submission.testSetupID, on: db) else { continue }
            guard let manifest = decodeManifest(from: Data(setup.manifest.utf8)) else { continue }
            resolvedBySetupID[submission.testSetupID] = (setup, manifest)
            candidates.append((submission, setup, manifest))
        }
        return candidates
    }

    /// Pairs each validation submission with its setup and manifest. An
    /// instructor is waiting on a validation run, so a missing setup or an
    /// undecodable manifest is an error, not a skip.
    private mutating func resolveStrictly(_ submissions: [APISubmission]) async throws -> [ClaimCandidate] {
        var candidates: [ClaimCandidate] = []
        candidates.reserveCapacity(submissions.count)
        for submission in submissions {
            if let cached = resolvedBySetupID[submission.testSetupID] {
                candidates.append((submission, cached.0, cached.1))
                continue
            }
            guard let setup = try await APITestSetup.find(submission.testSetupID, on: db) else {
                throw WorkerJobError.testSetupNotFound(id: submission.testSetupID)
            }
            let manifest = try ManifestCodec.decoder.decode(TestProperties.self, from: Data(setup.manifest.utf8))
            resolvedBySetupID[submission.testSetupID] = (setup, manifest)
            candidates.append((submission, setup, manifest))
        }
        return candidates
    }
}
