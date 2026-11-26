import Core
import Fluent
import Foundation
import Vapor

enum RunnerProfileRegistrationEvent: String, Sendable {
    case registered
    case updated
}

struct RunnerProfileUpsertResult: Sendable {
    let profile: RunnerProfile?
    let event: RunnerProfileRegistrationEvent?
}

struct LoadedAssignmentRequirement: Sendable {
    let assignmentID: UUID?
    let requirement: AssignmentRequirement?
}

struct RunnerProfileService {
    /// How stale the persisted `lastSeenAt` may get before an otherwise
    /// unchanged check-in writes it again. Runners poll at up to 1/s; without
    /// a debounce every poll is a row UPDATE (2026-07 audit). Must stay well
    /// under `RUNNER_ACTIVE_WINDOW_SECONDS` (default 120 s) so
    /// `refreshActiveFlags` never sees a live runner as stale: a live runner
    /// checks in at least every 30 s (heartbeat), so persisted freshness lags
    /// true freshness by at most ~`debounce` seconds. The live dashboard
    /// reads `WorkerActivityStore` (in-memory), not this column.
    static let lastSeenPersistInterval: TimeInterval = 60

    func registerOrUpdate(
        runnerID: String,
        displayName: String?,
        profile: RunnerCapabilityProfile?,
        seenAt: Date,
        on db: any Database,
        lastSeenPersistInterval: TimeInterval = RunnerProfileService.lastSeenPersistInterval
    ) async throws -> RunnerProfileUpsertResult {
        guard !runnerID.isEmpty else {
            return RunnerProfileUpsertResult(profile: nil, event: nil)
        }

        // A check-in that changes nothing but the freshness timestamp only
        // persists when the stored timestamp has aged past the debounce
        // window — the poll-frequency UPDATE-per-poll is the thing being
        // avoided here. Any real change (capabilities, display name,
        // reactivation) still writes immediately.
        // When it has aged, it writes `last_seen_at` alone (`persistFreshness`),
        // not the whole row.
        func changesOnlyFreshness(_ existing: RunnerProfile, displayNameChanged: Bool) -> Bool {
            !displayNameChanged && existing.isActive
        }
        func onlyRefreshesFreshness(_ existing: RunnerProfile, displayNameChanged: Bool) -> Bool {
            changesOnlyFreshness(existing, displayNameChanged: displayNameChanged)
                && seenAt.timeIntervalSince(existing.lastSeenAt) < lastSeenPersistInterval
        }

        // A new runner polls from every job slot at once, so its first
        // check-ins arrive together: each reads "no row", and only one insert
        // wins `uq:runner_profiles.runner_id`. A loser makes one more pass,
        // finds the winner's row and takes the update path, so it never
        // reports `.registered`: the winner already did.
        var mayRetryInsert = true
        while true {
            let existing = try await RunnerProfile.query(on: db)
                .filter(\.$runnerID == runnerID)
                .first()

            guard let profile else {
                if let existing {
                    let newName = nonEmpty(displayName)
                    let displayNameChanged = newName != nil && newName != existing.displayName
                    if onlyRefreshesFreshness(existing, displayNameChanged: displayNameChanged) {
                        return RunnerProfileUpsertResult(profile: existing, event: nil)
                    }
                    if changesOnlyFreshness(existing, displayNameChanged: displayNameChanged) {
                        try await persistFreshness(
                            of: existing, seenAt: seenAt, interval: lastSeenPersistInterval, on: db)
                        return RunnerProfileUpsertResult(profile: existing, event: nil)
                    }
                    existing.lastSeenAt = seenAt
                    existing.isActive = true
                    if let newName {
                        existing.displayName = newName
                    }
                    try await existing.save(on: db)
                }
                return RunnerProfileUpsertResult(profile: existing, event: nil)
            }

            let profileHash = self.profileHash(for: profile)
            if let existing {
                let event: RunnerProfileRegistrationEvent? = existing.profileHash == profileHash ? nil : .updated
                let newName = nonEmpty(displayName)
                let displayNameChanged = newName != nil && newName != existing.displayName
                if event == nil, onlyRefreshesFreshness(existing, displayNameChanged: displayNameChanged) {
                    return RunnerProfileUpsertResult(profile: existing, event: nil)
                }
                if event == nil, changesOnlyFreshness(existing, displayNameChanged: displayNameChanged) {
                    try await persistFreshness(
                        of: existing, seenAt: seenAt, interval: lastSeenPersistInterval, on: db)
                    return RunnerProfileUpsertResult(profile: existing, event: nil)
                }
                existing.displayName = newName ?? existing.displayName
                existing.capabilityProfile = profile
                existing.profileHash = profileHash
                existing.lastRegisteredAt = seenAt
                existing.lastSeenAt = seenAt
                existing.isActive = true
                try await existing.save(on: db)
                return RunnerProfileUpsertResult(profile: existing, event: event)
            }

            let created = RunnerProfile(
                runnerID: runnerID,
                displayName: nonEmpty(displayName),
                profile: profile,
                profileHash: profileHash,
                lastRegisteredAt: seenAt,
                lastSeenAt: seenAt,
                isActive: true
            )
            do {
                try await created.create(on: db)
                return RunnerProfileUpsertResult(profile: created, event: .registered)
            } catch  where mayRetryInsert && isInsertConflict(error) {
                mayRetryInsert = false
            }
        }
    }

    /// Writes `seenAt` as the runner's freshness when nothing else about the
    /// profile changed and the stored `last_seen_at` has aged past `interval`.
    /// It is one guarded UPDATE of that column (and of `updated_at`, which
    /// Fluent adds to a query update). Each slot of a runner holds its own poll
    /// on the server, so the slots check in at about the same moment and each
    /// reads the same aged row. A full-row save from each of them wrote every
    /// column (both JSON columns included) once per slot: production ran one
    /// such UPDATE per runner about every 22 s, not every 60 s (16,301 in 24.7
    /// h for four runners, 2026-11-22). With the guard, the first slot's write
    /// lands and the others change no row. `last_registered_at` does not move
    /// on this path. `existing.lastSeenAt` is set to `seenAt` either way, so
    /// the returned model can be ahead of the stored row by less than
    /// `interval`. Internal, not private, so a test can play two slots.
    func persistFreshness(
        of existing: RunnerProfile, seenAt: Date, interval: TimeInterval, on db: any Database
    ) async throws {
        let profileID = try existing.requireID()
        try await RunnerProfile.query(on: db)
            .set(\.$lastSeenAt, to: seenAt)
            .filter(\.$id == profileID)
            .filter(\.$lastSeenAt <= seenAt.addingTimeInterval(-interval))
            .update()
        existing.lastSeenAt = seenAt
    }

    func profile(for runnerID: String, on db: any Database) async throws -> RunnerProfile? {
        try await RunnerProfile.query(on: db)
            .filter(\.$runnerID == runnerID)
            .first()
    }

    /// The stored profile of each runner in `runnerIDs` that has one, keyed
    /// by runner ID: `profile(for:on:)` for many runners in one read.
    func profiles(for runnerIDs: [String], on db: any Database) async throws -> [String: RunnerProfile] {
        guard !runnerIDs.isEmpty else { return [:] }
        return Dictionary(
            try await RunnerProfile.query(on: db).filter(\.$runnerID ~~ runnerIDs).all().map { ($0.runnerID, $0) },
            uniquingKeysWith: { first, _ in first })
    }

    func refreshActiveFlags(activeWindowSeconds: TimeInterval, on db: any Database) async throws {
        let cutoff = Date().addingTimeInterval(-activeWindowSeconds)
        let profiles = try await RunnerProfile.query(on: db).all()
        for profile in profiles {
            let shouldBeActive = profile.lastSeenAt >= cutoff
            guard profile.isActive != shouldBeActive else { continue }
            profile.isActive = shouldBeActive
            try await profile.save(on: db)
        }
    }

    private func profileHash(for profile: RunnerCapabilityProfile) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(profile) else { return nil }
        return data.base64EncodedString()
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct AssignmentRequirementService {
    func loadRequirement(for submission: APISubmission, on db: any Database) async throws -> LoadedAssignmentRequirement
    {
        let assignment: APIAssignment?
        if submission.kind == APISubmission.Kind.validation, let submissionID = submission.id {
            assignment = try await APIAssignment.query(on: db)
                .filter(\.$validationSubmissionID == submissionID)
                .first()
        } else {
            assignment = try await assignmentByTestSetupID(submission.testSetupID, on: db)
        }

        guard let assignment, let assignmentID = assignment.id else {
            return LoadedAssignmentRequirement(assignmentID: nil, requirement: nil)
        }

        let requirement = try await AssignmentRequirement.query(on: db)
            .filter(\.$assignmentID == assignmentID)
            .first()
        return LoadedAssignmentRequirement(assignmentID: assignmentID, requirement: requirement)
    }
}

struct RunnerProfileServiceKey: StorageKey {
    typealias Value = RunnerProfileService
}

struct AssignmentRequirementServiceKey: StorageKey {
    typealias Value = AssignmentRequirementService
}

extension Application {
    var runnerProfiles: RunnerProfileService {
        get {
            if let existing = storage[RunnerProfileServiceKey.self] { return existing }
            let created = RunnerProfileService()
            storage[RunnerProfileServiceKey.self] = created
            return created
        }
        set { storage[RunnerProfileServiceKey.self] = newValue }
    }

    var assignmentRequirements: AssignmentRequirementService {
        get {
            if let existing = storage[AssignmentRequirementServiceKey.self] { return existing }
            let created = AssignmentRequirementService()
            storage[AssignmentRequirementServiceKey.self] = created
            return created
        }
        set { storage[AssignmentRequirementServiceKey.self] = newValue }
    }
}
