// APIServer/Routes/Web/RosterSnapshot.swift
//
// The students on one board, captured once and shared by every refresh that
// reads the same board (docs/live-board-cache.md). A refresh used to load and
// decode every ranked student's user and enrollment rows, which on a
// 150-student board was most of its cost, for each viewer on each poll.
//
// It holds values, never models, so concurrent requests can share it. A
// presentation built from it is the one `AvatarIdentity.presentation` builds:
// the capture runs the same `ensureHandle` and `ensureSpec`, once.

import Core
import Crypto
import Fluent
import Foundation

struct RosterSnapshot: Sendable, BoardIdentities {
    struct Member: Sendable, Equatable {
        let handle: String
        let staffFacingName: String
        let username: String
        let spec: AvatarSpec
        /// A TA or instructor, who wears the staff ring.
        let isStaff: Bool
    }

    /// Every student on the roster among the captured IDs.
    let members: [UUID: Member]
    /// Every ID the capture was asked for, on the roster or not.
    let capturedIDs: Set<UUID>
    /// A hash of every member, for the refresh's ETag: a new handle, bird,
    /// name or ring changes it, and nothing else does.
    let digest: String

    /// Loads `userIDs` once, as a board does, and keeps what its rows need.
    static func capture(userIDs: [UUID], courseID: UUID, on db: any Database) async throws -> RosterSnapshot {
        let identities = try await AvatarIdentity.load(userIDs: userIDs, courseID: courseID, on: db)
        var members: [UUID: Member] = [:]
        for userID in Set(userIDs) {
            guard let user = identities.userByID[userID], let enrollment = identities.enrollmentByUser[userID]
            else { continue }
            let handle = try await AvatarStore.ensureHandle(for: user, on: db) ?? ""
            let spec = try await AvatarStore.ensureSpec(for: user, on: db)
            members[userID] = Member(
                handle: handle, staffFacingName: AvatarIdentity.staffFacingName(user), username: user.username,
                spec: spec,
                isStaff: enrollment.role >= .ta)
        }
        return RosterSnapshot(members: members, capturedIDs: Set(userIDs), digest: try digest(of: members))
    }

    /// SHA-256 over the members in user order, as the first 32 hex digits.
    static func digest(of members: [UUID: Member]) throws(EncodingError) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var hasher = SHA256()
        for userID in members.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let member = members[userID] else { continue }
            let spec: Data
            do {
                spec = try encoder.encode(member.spec)
            } catch let error as EncodingError {
                throw error
            } catch {
                throw EncodingError.invalidValue(
                    member.spec, .init(codingPath: [], debugDescription: String(describing: error)))
            }
            let line = [
                userID.uuidString, member.handle, member.staffFacingName, member.username,
                member.isStaff ? "staff" : "student",
            ].joined(separator: "\u{1F}")
            hasher.update(data: Data(line.utf8))
            hasher.update(data: spec)
            hasher.update(data: Data([0x1E]))
        }
        return lowercaseHex(hasher.finalize().prefix(16))
    }

    /// True when the snapshot was captured for every one of `userIDs`, so a
    /// board built from it treats no ranked student as unknown.
    func covers(_ userIDs: some Sequence<UUID>) -> Bool {
        userIDs.allSatisfy(capturedIDs.contains)
    }

    func isOnRoster(_ userID: UUID) -> Bool {
        members[userID] != nil
    }

    func presentation(
        for userID: UUID, includeName: Bool, fallbackLabel: String, size: AvatarSize, on db: any Database
    ) async throws -> AvatarIdentity.Presentation? {
        guard let member = members[userID] else { return nil }
        let accessibility: AvatarAccessibility =
            member.handle.isEmpty ? .labelled(fallbackLabel) : .decorative
        return AvatarIdentity.Presentation(
            handle: member.handle,
            name: includeName ? member.staffFacingName : "",
            avatar: AvatarPresentation(
                for: member.spec, size: size, accessibility: accessibility, isStaff: member.isStaff))
    }

    func username(of userID: UUID) -> String? {
        members[userID]?.username
    }
}
