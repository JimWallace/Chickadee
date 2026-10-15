// APIServer/Migrations/MoveHandlesToBirds.swift
//
// One-time move of the handle from each course enrollment to the bird
// (docs/student-avatars.md §3). A user's bird takes the handle of their newest
// course. Handles were unique per course, so two users can share one: users
// are taken oldest account first, and a later user whose handle is already
// taken draws a new one. Users with no handle anywhere get one on first need.
// The enrollment column is left as it was. Full-queries `APIUser` and
// `APICourseEnrollment`, so it follows every migration that changes either.

import Core
import Fluent
import Foundation

struct MoveHandlesToBirds: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        let enrollments = try await APICourseEnrollment.query(on: database)
            .filter(\.$legacyAvatarHandle != nil)
            .with(\.$course)
            .all()
        var byUser: [UUID: [APICourseEnrollment]] = [:]
        for enrollment in enrollments { byUser[enrollment.userID, default: []].append(enrollment) }

        let users = try await APIUser.query(on: database).sort(\.$createdAt, .ascending).all()
        var taken = Set(users.compactMap(\.avatarHandle))
        for user in users where user.avatarHandle == nil {
            guard let userID = user.id, let own = byUser[userID] else { continue }
            let newestFirst = own.sorted { lhs, rhs in
                if courseListPrecedes(lhs.course, rhs.course) { return true }
                if courseListPrecedes(rhs.course, lhs.course) { return false }
                return (lhs.enrolledAt ?? .distantPast) > (rhs.enrolledAt ?? .distantPast)
            }
            let kept = newestFirst.compactMap(\.legacyAvatarHandle)
                .first { AvatarHandle.hasHandleShape($0) && !taken.contains($0) }
            guard let handle = kept ?? AvatarHandle.make(excluding: taken) else { continue }
            user.avatarHandle = handle
            try await user.save(on: database)
            taken.insert(handle)
        }
    }

    func revert(on database: any Database) async throws {
        try await APIUser.query(on: database).set(\.$avatarHandle, to: nil).update()
    }
}
