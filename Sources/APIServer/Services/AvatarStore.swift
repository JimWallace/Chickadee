// APIServer/Services/AvatarStore.swift
//
// First-use materialization for the two halves of a student's pseudonymous
// identity: the bird (its spec) and the bird's handle, both per user. A hatch
// replaces both (AvatarStore+Hatch.swift).
//
// Both are drawn once and stored, never re-derived.  See
// docs/student-avatars.md — re-deriving a spec on each render means appending
// one option to one slot reshuffles every existing avatar, and re-deriving a
// handle means a student's name changes when the word lists change.

import Core
import Fluent
import Foundation
import Vapor

enum AvatarStore {

    /// This person's own seeded bird as a roster cell: the roster size, and
    /// decorative because the row names them beside it. `isStaff` draws the
    /// staff ring; the caller decides it from the role the page is about
    /// (docs/student-wardrobe.md, "The staff ring").
    static func rosterAvatar(
        for user: APIUser, isStaff: Bool, on db: any Database
    ) async throws
        -> AvatarPresentation
    {
        let spec = try await ensureSpec(for: user, on: db)
        return AvatarPresentation(for: spec, size: .roster, accessibility: .decorative, isStaff: isStaff)
    }

    /// This user's stored avatar, drawing and saving one on first call.  A
    /// spec stored before a later axis gets that axis from its decoder default;
    /// a one-time migration, since deleted, stored the draw once (#1762).
    ///
    /// - Important: do NOT call inside an enclosing `db.transaction { … }`.
    ///   On Postgres a failed write aborts the whole transaction, so the
    ///   recover-by-refetch below would itself throw — the same rule, and the
    ///   same reason, as `AssignmentSeedStore.ensureSeed`.
    static func ensureSpec(for user: APIUser, on db: any Database) async throws -> AvatarSpec {
        // A stored bird is returned as it is. An axis added after a bird was
        // stored was filled once, by a migration, not on every read.
        if let stored = user.avatarSpecJSON, let decoded = decode(stored) { return decoded }
        let spec = AvatarSpec.drawn()
        user.avatarSpecJSON = encode(spec)
        do {
            try await user.save(on: db)
        } catch {
            // Another request materialized first, or the row moved under us.
            // The avatar is cosmetic: a student seeing their bird is never
            // worth failing their account page over, so fall back to the
            // freshly drawn one and let the next load persist it.
            //
            // `try?`, not `try`, and that distinction is the whole point. On
            // Postgres a failed write inside a transaction poisons it, so the
            // recovering read throws too — and a `try` here would turn a lost
            // race on a cosmetic column into a 500 on the account page, which
            // is precisely what the comment above says must never happen. The
            // drawn spec is a perfectly good answer; the next load persists it.
            let winner = (try? await APIUser.find(user.id, on: db)).flatMap { $0?.avatarSpecJSON }
            if let winner, let stored = decode(winner) { return stored }
        }
        return spec
    }

    // MARK: - The bird's handle (docs/student-avatars.md §3)

    /// This user's bird's handle, drawing and saving one on first call. One
    /// handle names the bird in every course, so it is unique across the
    /// deployment.
    ///
    /// Returns nil only when the word lists are exhausted, which is a real
    /// condition (more birds than `AvatarHandle.combinationCount`) rather
    /// than an error to swallow: the caller renders without a handle and the
    /// bird still shows.
    static func ensureHandle(for user: APIUser, on db: any Database) async throws -> String? {
        if let handle = user.avatarHandle, AvatarHandle.hasHandleShape(handle) { return handle }
        return try await ensureHandle(for: user, taken: takenHandles(on: db), on: db)
    }

    /// `ensureHandle(for:on:)` with the taken handles already loaded, for a
    /// page that draws more than one handle (#1759).
    static func ensureHandle(
        for user: APIUser, taken: Set<String>, on db: any Database
    ) async throws -> String? {
        // Shape, not list membership: a handle from an earlier word list is
        // kept, because a list change must never rename a student.
        if let handle = user.avatarHandle, AvatarHandle.hasHandleShape(handle) { return handle }
        guard let handle = AvatarHandle.make(excluding: taken) else { return nil }
        user.avatarHandle = handle
        do {
            try await user.save(on: db)
            return handle
        } catch {
            // Lost the unique-index race, or the row moved under us. Re-read
            // the winner rather than looping: if the row now has a handle it
            // is ours to show, and if not the next page load tries again.
            //
            // `try?` for the same reason as `ensureSpec`: on Postgres the
            // failed save has already aborted the transaction, so this read
            // throws as well, and a handle is never worth failing the page for.
            let winner = (try? await APIUser.find(user.id, on: db)).flatMap { $0?.avatarHandle }
            user.avatarHandle = winner
            return winner
        }
    }

    /// The handle of the bird of the user enrolled in `enrollment`, drawing
    /// one on first call. For the course pages, which hold the enrollment.
    static func ensureHandle(for enrollment: APICourseEnrollment, on db: any Database) async throws -> String? {
        guard let user = try await APIUser.find(enrollment.userID, on: db) else { return nil }
        return try await ensureHandle(for: user, on: db)
    }

    /// The stored handle of each of `userIDs` that has one. Reads only; for a
    /// list that shows handles without drawing them.
    static func handles(for userIDs: [UUID], on db: any Database) async throws -> [UUID: String] {
        guard !userIDs.isEmpty else { return [:] }
        var handles: [UUID: String] = [:]
        for user in try await APIUser.query(on: db).filter(\.$id ~~ userIDs).filter(\.$avatarHandle != nil).all() {
            if let id = user.id, let handle = user.avatarHandle { handles[id] = handle }
        }
        return handles
    }

    /// Every handle a bird holds now. The one query behind every draw and
    /// check: one column, rows with a handle only (#1759).
    static func takenHandles(on db: any Database) async throws -> Set<String> {
        Set(
            try await APIUser.query(on: db)
                .filter(\.$avatarHandle != nil)
                .all(\.$avatarHandle)
                .compactMap(\.self))
    }

    /// Replaces this user's bird's handle with a fresh draw from the current
    /// lists. This is the staff "Give new handle" action, for a handle that
    /// must change (a student reports that it matches a real name). It
    /// changes the name in every course.
    ///
    /// Returns nil when the lists are exhausted, and leaves the old handle in
    /// place. A lost unique-index race is retried with the winner's handle
    /// excluded; any other failure is thrown, so an outage is never reported
    /// as an exhausted pool (#2255).
    static func redrawHandle(for user: APIUser, on db: any Database) async throws -> String? {
        try await redrawHandle(for: user, taken: takenHandles(on: db), on: db)
    }

    /// `redrawHandle(for:on:)` from a taken set the caller already loaded.
    static func redrawHandle(
        for user: APIUser, taken: Set<String>, on db: any Database
    ) async throws -> String? {
        var taken = taken
        let previous = user.avatarHandle
        for _ in 0..<3 {
            guard let handle = AvatarHandle.make(excluding: taken) else { break }
            user.avatarHandle = handle
            do {
                try await user.save(on: db)
                return handle
            } catch {
                // Retry only a lost race: the index refused a handle that
                // another bird now holds.
                guard (try? await takenHandles(on: db).contains(handle)) == true else {
                    user.avatarHandle = previous
                    throw error
                }
                taken.insert(handle)
            }
        }
        user.avatarHandle = previous
        return nil
    }

    /// Whether `handle` is free for `userID`'s bird: no other bird holds it.
    static func isHandleFree(_ handle: String, for userID: UUID, on db: any Database) async throws -> Bool {
        try await APIUser.query(on: db)
            .filter(\.$avatarHandle == handle)
            .filter(\.$id != userID)
            .count() == 0
    }

    // MARK: - The staff ring

    /// The users among `userIDs` who are course staff (TA or instructor) in at
    /// least one course that is not archived. For the pages that belong to no
    /// one course — the account page and the admin Users list — where the
    /// staff ring means "teaches somewhere". A page inside a course asks that
    /// course's enrollment role instead (docs/student-wardrobe.md, "The staff
    /// ring"). An archived offering does not count: a student who was a TA in
    /// a past term is a student now, and gets their own ring back (#1756).
    static func courseStaff(among userIDs: [UUID], on db: any Database) async throws -> Set<UUID> {
        guard !userIDs.isEmpty else { return [] }
        let enrollments = try await APICourseEnrollment.query(on: db)
            .filter(\.$userID ~~ userIDs)
            .join(APICourse.self, on: \APICourseEnrollment.$course.$id == \APICourse.$id)
            .filter(APICourse.self, \.$isArchived == false)
            .all()
        return Set(enrollments.filter { $0.role >= .ta }.map(\.userID))
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
