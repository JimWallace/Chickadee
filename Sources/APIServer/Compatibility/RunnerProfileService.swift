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
        on db: Database,
        lastSeenPersistInterval: TimeInterval = RunnerProfileService.lastSeenPersistInterval
    ) async throws -> RunnerProfileUpsertResult {
        guard !runnerID.isEmpty else {
            return RunnerProfileUpsertResult(profile: nil, event: nil)
        }

        let existing = try await RunnerProfile.query(on: db)
            .filter(\.$runnerID == runnerID)
            .first()

        // A check-in that changes nothing but the freshness timestamp only
        // persists when the stored timestamp has aged past the debounce
        // window — the poll-frequency UPDATE-per-poll is the thing being
        // avoided here. Any real change (capabilities, display name,
        // reactivation) still writes immediately.
        func onlyRefreshesFreshness(_ existing: RunnerProfile, displayNameChanged: Bool) -> Bool {
            !displayNameChanged
                && existing.isActive
                && seenAt.timeIntervalSince(existing.lastSeenAt) < lastSeenPersistInterval
        }

        guard let profile else {
            if let existing {
                let newName = nonEmpty(displayName)
                let displayNameChanged = newName != nil && newName != existing.displayName
                if onlyRefreshesFreshness(existing, displayNameChanged: displayNameChanged) {
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
        try await created.save(on: db)
        return RunnerProfileUpsertResult(profile: created, event: .registered)
    }

    func profile(for runnerID: String, on db: Database) async throws -> RunnerProfile? {
        try await RunnerProfile.query(on: db)
            .filter(\.$runnerID == runnerID)
            .first()
    }

    func refreshActiveFlags(activeWindowSeconds: TimeInterval, on db: Database) async throws {
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
    func loadRequirement(for submission: APISubmission, on db: Database) async throws -> LoadedAssignmentRequirement {
        let assignment: APIAssignment?
        if submission.kind == APISubmission.Kind.validation, let submissionID = submission.id {
            assignment = try await APIAssignment.query(on: db)
                .filter(\.$validationSubmissionID == submissionID)
                .first()
        } else {
            assignment = try await APIAssignment.query(on: db)
                .filter(\.$testSetupID == submission.testSetupID)
                .first()
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
