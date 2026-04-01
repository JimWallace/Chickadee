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
    func registerOrUpdate(
        runnerID: String,
        displayName: String?,
        profile: RunnerCapabilityProfile?,
        seenAt: Date,
        on db: Database
    ) async throws -> RunnerProfileUpsertResult {
        guard !runnerID.isEmpty else {
            return RunnerProfileUpsertResult(profile: nil, event: nil)
        }

        let existing = try await RunnerProfile.query(on: db)
            .filter(\.$runnerID == runnerID)
            .first()

        guard let profile else {
            if let existing {
                existing.lastSeenAt = seenAt
                existing.isActive = true
                if let displayName, !displayName.isEmpty {
                    existing.displayName = displayName
                }
                try await existing.save(on: db)
            }
            return RunnerProfileUpsertResult(profile: existing, event: nil)
        }

        let profileHash = self.profileHash(for: profile)
        if let existing {
            let event: RunnerProfileRegistrationEvent? = existing.profileHash == profileHash ? nil : .updated
            existing.displayName = nonEmpty(displayName) ?? existing.displayName
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
