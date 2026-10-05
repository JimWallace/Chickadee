// APIServer/Services/AvatarStore.swift
//
// First-use materialization for the two halves of a student's pseudonymous
// identity: the avatar spec (per user) and the handle (per user, per course).
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
        for user: APIUser, isStaff: Bool, on db: Database
    ) async throws
        -> AvatarPresentation
    {
        let spec = try await ensureSpec(for: user, on: db)
        return AvatarPresentation(for: spec, size: .roster, accessibility: .decorative, isStaff: isStaff)
    }

    /// This user's stored avatar, drawing and saving one on first call, and
    /// filling any axis added since it was stored.
    ///
    /// - Important: do NOT call inside an enclosing `db.transaction { … }`.
    ///   On Postgres a failed write aborts the whole transaction, so the
    ///   recover-by-refetch below would itself throw — the same rule, and the
    ///   same reason, as `AssignmentSeedStore.ensureSeed`.
    static func ensureSpec(for user: APIUser, on db: Database) async throws -> AvatarSpec {
        // A stored bird is returned as it is. An axis added after a bird was
        // stored is filled once, by `FillLateAvatarAxes`, not on every read.
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

    /// This enrollment's handle, generating and saving one on first call.
    ///
    /// Returns nil only when the course has exhausted the word lists, which is
    /// a real condition (a course larger than `AvatarHandle.combinationCount`)
    /// rather than an error to swallow — the caller renders without a handle
    /// and the avatar still shows.
    static func ensureHandle(
        for enrollment: APICourseEnrollment, on db: Database
    ) async throws -> String? {
        // Shape, not list membership: a handle from an earlier word list is
        // kept, because a list change must never rename a student mid-term.
        if let handle = enrollment.avatarHandle, AvatarHandle.hasHandleShape(handle) {
            return handle
        }
        return try await ensureHandle(
            for: enrollment, taken: takenHandles(inCourse: enrollment.$course.id, on: db), on: db)
    }

    /// `ensureHandle(for:on:)` with the course's taken handles already
    /// loaded, for a page that draws more than once per enrollment (#1759).
    static func ensureHandle(
        for enrollment: APICourseEnrollment, taken: Set<String>, on db: Database
    ) async throws -> String? {
        if let handle = enrollment.avatarHandle, AvatarHandle.hasHandleShape(handle) {
            return handle
        }
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
            //
            // `try?` for the same reason as `ensureSpec`: on Postgres the
            // failed save has already aborted the transaction, so this read
            // throws as well, and a handle is never worth failing the page for.
            let winner = (try? await APICourseEnrollment.find(enrollment.id, on: db))
                .flatMap { $0?.avatarHandle }
            enrollment.avatarHandle = winner
            return winner
        }
    }

    /// Replaces this enrollment's handle with a fresh draw from the current
    /// lists.  This is the staff "Give new handle" action, for a handle that
    /// must change (a student reports that it matches a real name).  Nothing
    /// calls it automatically: a list change never renames a student mid-term.
    ///
    /// Returns nil when the course has exhausted the current lists, and leaves
    /// the old handle in place.  A lost unique-index race is retried with the
    /// winner's handle excluded.
    static func redrawHandle(
        for enrollment: APICourseEnrollment, on db: Database
    ) async throws -> String? {
        var taken = try await takenHandles(inCourse: enrollment.$course.id, on: db)
        let previous = enrollment.avatarHandle
        for _ in 0..<3 {
            guard let handle = AvatarHandle.make(excluding: taken) else { break }
            enrollment.avatarHandle = handle
            do {
                try await enrollment.save(on: db)
                return handle
            } catch {
                taken.insert(handle)
            }
        }
        enrollment.avatarHandle = previous
        return nil
    }

    // MARK: - The student's one choice (docs/student-avatars.md §3)

    /// Every handle already stored in this course. The one query behind every
    /// draw and check: one column, rows with a handle only, never the full
    /// enrollment rows (#1759).
    static func takenHandles(inCourse courseID: UUID, on db: Database) async throws -> Set<String> {
        Set(
            try await APICourseEnrollment.query(on: db)
                .filter(\.$course.$id == courseID)
                .filter(\.$avatarHandle != nil)
                .all(\.$avatarHandle)
                .compactMap { $0 })
    }

    /// Unused handles from the current lists, two by default, for the account
    /// page's "Change handle" panel, drawn from a taken set the caller loaded.
    /// They are not reserved: the choice is checked again against the unique
    /// index when the student picks one.  Fewer than `count` when the course
    /// has nearly exhausted the lists.
    static func drawAlternates(taken: Set<String>, count: Int = 2) -> [String] {
        var taken = taken
        var alternates: [String] = []
        while alternates.count < count, let handle = AvatarHandle.make(excluding: taken) {
            alternates.append(handle)
            taken.insert(handle)
        }
        return alternates
    }

    /// Whether an offered alternate can still be picked: from the current
    /// lists and not stored by anybody in the course.
    static func isStillAvailable(_ handle: String, taken: Set<String>) -> Bool {
        AvatarHandle.isWellFormed(handle) && !taken.contains(handle)
    }

    enum HandleChoice: Equatable {
        /// The handle is now the student's, and it is locked.
        case chosen
        /// The handle was already locked; nothing changed.
        case locked
        /// Somebody else stored this handle first; nothing changed.
        case taken
    }

    /// The student's one change.  Saves `handle` and locks it in the same
    /// write, so a second change is refused.  The caller has already checked
    /// that `handle` was one of the alternates it offered.
    static func chooseHandle(
        _ handle: String, for enrollment: APICourseEnrollment, on db: Database
    ) async throws -> HandleChoice {
        guard enrollment.avatarHandleLockedAt == nil else { return .locked }
        let courseID = enrollment.$course.id
        guard try await !takenHandles(inCourse: courseID, on: db).contains(handle) else { return .taken }

        let previous = enrollment.avatarHandle
        enrollment.avatarHandle = handle
        enrollment.avatarHandleLockedAt = Date()
        do {
            try await enrollment.save(on: db)
            return .chosen
        } catch {
            enrollment.avatarHandle = previous
            enrollment.avatarHandleLockedAt = nil
            // A concurrent pick of the same handle loses on the unique index.
            // Anything else is a real failure.
            if (try? await takenHandles(inCourse: courseID, on: db).contains(handle)) == true {
                return .taken
            }
            throw error
        }
    }

    /// Locks this enrollment's handle, because somebody other than the student
    /// or staff has now seen it.  A no-op once locked, and never worth failing
    /// the page that showed the handle.
    static func lockHandle(for enrollment: APICourseEnrollment, on db: Database) async {
        guard enrollment.avatarHandle != nil, enrollment.avatarHandleLockedAt == nil else { return }
        enrollment.avatarHandleLockedAt = Date()
        do {
            try await enrollment.save(on: db)
        } catch {
            enrollment.avatarHandleLockedAt = nil
        }
    }

    // MARK: - The staff ring

    /// The users among `userIDs` who are course staff (TA or instructor) in at
    /// least one course that is not archived. For the pages that belong to no
    /// one course — the account page and the admin Users list — where the
    /// staff ring means "teaches somewhere". A page inside a course asks that
    /// course's enrollment role instead (docs/student-wardrobe.md, "The staff
    /// ring"). An archived offering does not count: a student who was a TA in
    /// a past term is a student now, and gets their own ring back (#1756).
    static func courseStaff(among userIDs: [UUID], on db: Database) async throws -> Set<UUID> {
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
