// APIServer/Services/AssignmentSeedStore.swift
//
// Phase 1 of issue #461 — lazy per-(user, assignment) seed generation.
//
// `ensureSeed` returns the existing seed for a (user, assignment) pair,
// generating a fresh 32-byte random hex string on first call. Concurrency
// safety comes from the UNIQUE(user_id, assignment_id) constraint on
// assignment_personalization_seeds: under a race, the loser's INSERT fails
// and we re-fetch the winner.

import Fluent
import Foundation
import Vapor

enum AssignmentSeedStore {

    /// Hex-encoded 32 random bytes = 64 hex characters. Surfaced verbatim to
    /// `CHICKADEE_ASSIGNMENT_SEED` in grading subprocesses.
    static let seedByteCount = 32

    /// Look up an existing seed for `(userID, assignmentID)`; create one if absent.
    /// Idempotent under concurrent calls thanks to the UNIQUE constraint.
    static func ensureSeed(
        userID: UUID,
        assignmentID: UUID,
        on db: Database
    ) async throws -> String {
        if let existing = try await findSeed(userID: userID, assignmentID: assignmentID, on: db) {
            return existing
        }

        let newSeed = generateSeedHex()
        let row = APIAssignmentPersonalizationSeed(
            userID: userID,
            assignmentID: assignmentID,
            seedValue: newSeed
        )

        do {
            try await row.save(on: db)
            return newSeed
        } catch {
            // UNIQUE constraint race: another request inserted first. Re-fetch
            // and return the winner.
            if let winner = try await findSeed(userID: userID, assignmentID: assignmentID, on: db) {
                return winner
            }
            throw error
        }
    }

    private static func findSeed(
        userID: UUID,
        assignmentID: UUID,
        on db: Database
    ) async throws -> String? {
        try await APIAssignmentPersonalizationSeed.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$assignmentID == assignmentID)
            .first()
            .map(\.seedValue)
    }

    /// Generates `seedByteCount` random bytes from `SystemRandomNumberGenerator`
    /// and returns them as a lowercase hex string (length = 2 * seedByteCount).
    static func generateSeedHex() -> String {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(seedByteCount)
        // Each call produces 8 random bytes; pull enough to fill the buffer.
        while bytes.count < seedByteCount {
            var word = rng.next()
            for _ in 0..<MemoryLayout<UInt64>.size where bytes.count < seedByteCount {
                bytes.append(UInt8(truncatingIfNeeded: word))
                word >>= 8
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
