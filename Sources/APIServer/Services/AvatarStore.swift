// APIServer/Services/AvatarStore.swift
//
// First-use materialization for the two halves of a student's pseudonymous
// identity: the avatar spec (per user) and the handle (per user, per course).
//
// Both are drawn once and stored, never re-derived.  See
// docs/student-avatars.md — re-deriving a spec on each render means appending
// one option to one slot reshuffles every existing avatar, and re-deriving a
// handle means a student's name changes when the word lists grow.

import Core
import Fluent
import Foundation
import Vapor

enum AvatarStore {

    /// This user's stored avatar, drawing and saving one on first call.
    ///
    /// - Important: do NOT call inside an enclosing `db.transaction { … }`.
    ///   On Postgres a failed write aborts the whole transaction, so the
    ///   recover-by-refetch below would itself throw — the same rule, and the
    ///   same reason, as `AssignmentSeedStore.ensureSeed`.
    static func ensureSpec(for user: APIUser, on db: Database) async throws -> AvatarSpec {
        if let stored = user.avatarSpecJSON, let spec = decode(stored) { return spec }

        let spec = AvatarSpec.drawn()
        user.avatarSpecJSON = encode(spec)
        do {
            try await user.save(on: db)
        } catch {
            // Another request materialized first, or the row moved under us.
            // The avatar is cosmetic: a student seeing their bird is never
            // worth failing their account page over, so fall back to the
            // freshly drawn one and let the next load persist it.
            if let winner = try await APIUser.find(user.id, on: db)?.avatarSpecJSON,
                let spec = decode(winner)
            {
                return spec
            }
        }
        return spec
    }

    /// This enrollment's handle, generating and saving one on first call.
    ///
    /// Returns nil only when the course has exhausted the word lists, which is
    /// a real condition (a course larger than `AvatarHandle.combinationCount`)
    /// rather than an error to swallow — the caller renders without a handle
    /// and the avatar still shows.
    static func ensureHandle(
        for enrollment: APICourseEnrollment, on db: Database
    ) async throws -> String? {
        if let handle = enrollment.avatarHandle, AvatarHandle.isWellFormed(handle) {
            return handle
        }
        let courseID = enrollment.$course.id
        let taken = Set(
            try await APICourseEnrollment.query(on: db)
                .filter(\.$course.$id == courseID)
                .all()
                .compactMap(\.avatarHandle))
        guard let handle = AvatarHandle.make(excluding: taken) else { return nil }

        enrollment.avatarHandle = handle
        do {
            try await enrollment.save(on: db)
            return handle
        } catch {
            // Lost the unique index race with a concurrent enrollment read of
            // the same remainder. Re-read the winner rather than looping: if
            // the row now has a handle it is ours to show, and if it does not
            // the next page load tries again.
            let winner = try await APICourseEnrollment.find(enrollment.id, on: db)?.avatarHandle
            enrollment.avatarHandle = winner
            return winner
        }
    }

    // MARK: - Coding

    /// A spec whose stored JSON no longer decodes — a slot renamed, a row
    /// hand-edited — is treated as absent and redrawn rather than crashing a
    /// page. Losing one cosmetic choice beats a 500 on the account page.
    static func decode(_ json: String) -> AvatarSpec? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AvatarSpec.self, from: data)
    }

    static func encode(_ spec: AvatarSpec) -> String? {
        guard let data = try? JSONEncoder().encode(spec) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
