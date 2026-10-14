// APIServer/Services/AvatarStore+Hatch.swift
//
// "Hatch a new bird" and "Go back" (Core/AvatarHatch.swift). A hatch is the
// only way a stored bird's species changes: nothing else may redraw it
// (docs/student-avatars.md, decision 2).

import Core
import Fluent
import Foundation

/// What the account page needs to know about a user's hatches.
struct AvatarHatchStatus: Sendable {
    /// The hatches used in the current term.
    let used: Int
    /// When the current bird hatched: the newest hatch, or nil when the user
    /// has never hatched (the page then uses the account's creation date).
    let lastHatchedAt: Date?
    /// The bird before the last hatch, while the user can still go back to it.
    let previous: AvatarSpec?

    var left: Int { max(0, AvatarHatch.perTerm - used) }
}

extension AvatarStore {

    /// `user`'s hatch status during `term`.
    static func hatchStatus(
        for user: APIUser, term: AcademicTerm, on db: any Database
    ) async throws -> AvatarHatchStatus {
        let userID = try user.requireID()
        let used = try await hatchesUsed(userID: userID, termKey: AvatarHatch.termKey(for: term), on: db)
        let newest = try await APIAvatarHatch.query(on: db)
            .filter(\.$userID == userID)
            .sort(\.$createdAt, .descending)
            .first()
        return AvatarHatchStatus(
            used: used, lastHatchedAt: newest?.createdAt,
            previous: user.avatarPreviousSpecJSON.flatMap(decode))
    }

    /// Hatches a new bird for `user` during `term`: the current bird becomes
    /// the previous one, and a bird of another species, with the same
    /// backdrop and ring, becomes the current one. Returns false, and changes
    /// nothing, when no hatch is left this term.
    ///
    /// The user row is read again inside the transaction, so a stale copy
    /// never overwrites a newer bird. Two requests at once both try the same
    /// `slot`, and the unique index refuses the second one.
    ///
    /// Call `ensureSpec` first, outside the transaction: the user must have a
    /// stored bird.
    static func hatch(for user: APIUser, term: AcademicTerm, on db: any Database) async throws -> Bool {
        let userID = try user.requireID()
        let termKey = AvatarHatch.termKey(for: term)
        let usedBefore = try await hatchesUsed(userID: userID, termKey: termKey, on: db)
        do {
            return try await db.transaction { db in
                let used = try await hatchesUsed(userID: userID, termKey: termKey, on: db)
                guard used < AvatarHatch.perTerm,
                    let fresh = try await APIUser.find(userID, on: db),
                    let current = fresh.avatarSpecJSON.flatMap(decode)
                else { return false }
                try await APIAvatarHatch(userID: userID, termKey: termKey, slot: used + 1).create(on: db)
                fresh.avatarPreviousSpecJSON = encode(current)
                fresh.avatarSpecJSON = encode(AvatarSpec.drawn(excluding: current.species, keeping: current))
                try await fresh.save(on: db)
                return true
            }
        } catch {
            // A concurrent hatch took the slot: it is the hatch, and this
            // request changes nothing. Anything else is a real error.
            if try await hatchesUsed(userID: userID, termKey: termKey, on: db) > usedBefore { return false }
            throw error
        }
    }

    /// Puts `user`'s previous bird back and forgets it. The backdrop and the
    /// ring of the current bird stay, as they do on a hatch. Returns false,
    /// and changes nothing, when there is no previous bird. A go back does
    /// not give the hatch back.
    static func restorePreviousBird(for user: APIUser, on db: any Database) async throws -> Bool {
        let userID = try user.requireID()
        return try await db.transaction { db in
            guard let fresh = try await APIUser.find(userID, on: db),
                var previous = fresh.avatarPreviousSpecJSON.flatMap(decode),
                let current = fresh.avatarSpecJSON.flatMap(decode)
            else { return false }
            previous.backdrop = current.backdrop
            previous.border = current.border
            fresh.avatarSpecJSON = encode(previous)
            fresh.avatarPreviousSpecJSON = nil
            try await fresh.save(on: db)
            return true
        }
    }

    private static func hatchesUsed(userID: UUID, termKey: String, on db: any Database) async throws -> Int {
        try await APIAvatarHatch.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$termKey == termKey)
            .count()
    }
}
