// APIServer/Routes/Web/AvatarIdentity.swift
//
// How a class activity page names a student: the bird's handle and the bird,
// never the name, with the staff ring on a TA or instructor
// (docs/student-avatars.md §3). Staff also see the name. Moved out of
// `WebRoutes+Leaderboard.swift` (#2720).

import Core
import Fluent
import Foundation

/// The users and enrollments behind a set of students on an activity page,
/// loaded in two queries, and the handle-and-bird presentation of each. The
/// one place a page builds a student's handle, bird, label and staff ring:
/// the ranking rows, the hill's champion and the viewer's own card all read
/// it.
struct AvatarIdentity {
    let userByID: [UUID: APIUser]
    let enrollmentByUser: [UUID: APICourseEnrollment]

    struct Presentation {
        let handle: String
        let name: String
        let avatar: AvatarPresentation
    }

    static func load(userIDs: [UUID], courseID: UUID, on db: any Database) async throws -> AvatarIdentity {
        let ids = Array(Set(userIDs))
        let users = try await APIUser.query(on: db).filter(\.$id ~~ ids).all()
        var userByID: [UUID: APIUser] = [:]
        for user in users { if let id = user.id { userByID[id] = user } }
        let enrollments = try await APICourseEnrollment.query(on: db)
            .filter(\.$course.$id == courseID)
            .filter(\.$userID ~~ ids)
            .all()
        var enrollmentByUser: [UUID: APICourseEnrollment] = [:]
        for enrollment in enrollments { enrollmentByUser[enrollment.userID] = enrollment }
        try await drawMissingHandles(users, on: db)
        return AvatarIdentity(userByID: userByID, enrollmentByUser: enrollmentByUser)
    }

    /// Draws a handle for each ranked bird that has none, reading the taken
    /// handles once for the page rather than once per row (#2257).
    /// `presentation` then finds every handle already in place.
    private static func drawMissingHandles(_ users: [APIUser], on db: any Database) async throws {
        var taken: Set<String>?
        for user in users where !(user.avatarHandle.map(AvatarHandle.hasHandleShape) ?? false) {
            var current: Set<String>
            if let taken {
                current = taken
            } else {
                current = try await AvatarStore.takenHandles(on: db)
            }
            if let handle = try await AvatarStore.ensureHandle(for: user, taken: current, on: db) {
                current.insert(handle)
            }
            taken = current
        }
    }

    /// False for a student who has since dropped: the roster is what a
    /// classmate is ranked against.
    func isOnRoster(_ userID: UUID) -> Bool {
        userByID[userID] != nil && enrollmentByUser[userID] != nil
    }

    /// nil when `isOnRoster` is false.
    func presentation(
        for userID: UUID, includeName: Bool, fallbackLabel: String,
        size: AvatarSize = .small, on db: any Database
    ) async throws -> Presentation? {
        guard let user = userByID[userID], let enrollment = enrollmentByUser[userID] else { return nil }
        let handle = try await AvatarStore.ensureHandle(for: user, on: db) ?? ""
        let spec = try await AvatarStore.ensureSpec(for: user, on: db)
        // Decorative when the handle carries the identity; the bird must
        // announce whose it is only when there is no handle beside it.
        let accessibility: AvatarAccessibility = handle.isEmpty ? .labelled(fallbackLabel) : .decorative
        return Presentation(
            handle: handle,
            name: includeName ? staffFacingName(user) : "",
            avatar: AvatarPresentation(
                for: spec, size: size, accessibility: accessibility, isStaff: enrollment.role >= .ta))
    }
}

/// The name staff see beside a handle: the display name when the roster has
/// one, else the username.
private func staffFacingName(_ user: APIUser) -> String {
    let display = user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return display.isEmpty ? user.username : display
}

/// The name the type had before #2720. `RankedIdentitiesHandleTests` uses it.
typealias RankedIdentities = AvatarIdentity
