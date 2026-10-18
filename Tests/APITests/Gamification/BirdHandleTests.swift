// Tests/APITests/Gamification/BirdHandleTests.swift
//
// The handle names the bird (docs/student-avatars.md §3). A hatch gives the bird a new handle, unique across the deployment; a go back gives
// the old one back while it is free; and the data export carries both.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3))) final class BirdHandleTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-bird-handle")
    }

    private static let term = AcademicTerm(year: 2026, season: .fall)

    /// The term the hatches count against.
    private func hatchTerm() throws -> AcademicTerm { try #require(Self.term) }

    /// Two handles from the lists, so the store treats them as real ones.
    private static let first = "\(AvatarHandle.scienceWords[0]) \(AvatarHandle.agents[0])"
    private static let second = "\(AvatarHandle.scienceWords[1]) \(AvatarHandle.agents[1])"

    private func stored(_ user: APIUser) async throws -> APIUser {
        try #require(try await APIUser.find(user.id, on: app.db))
    }

    /// A student with a stored bird and `handle`.
    private func birdWithHandle(_ username: String, _ handle: String?) async throws -> APIUser {
        let user = try await makeTestStudent(on: app, username: username)
        _ = try await AvatarStore.ensureSpec(for: user, on: app.db)
        user.avatarHandle = handle
        try await user.save(on: app.db)
        return user
    }

    // MARK: - Hatch and go back

    @Test func aHatchGivesTheBirdANewHandleAndKeepsTheOldOneToGoBackTo() async throws {
        try await withApp(app) { _ in
            let student = try await birdWithHandle("bh_hatch", Self.first)

            #expect(try await AvatarStore.hatch(for: student, term: try hatchTerm(), on: app.db))

            let hatched = try await stored(student)
            let handle = try #require(hatched.avatarHandle)
            #expect(handle != Self.first)
            #expect(AvatarHandle.allHandles.contains(handle))
            #expect(hatched.avatarPreviousHandle == Self.first)
            let status = try await AvatarStore.hatchStatus(for: hatched, term: try hatchTerm(), on: app.db)
            #expect(status.previousHandle == Self.first)
        }
    }

    /// The new handle is unique across the deployment: it is never one that
    /// another bird holds.
    @Test func aHatchNeverDrawsAHandleThatAnotherBirdHolds() async throws {
        try await withApp(app) { _ in
            let holder = try await birdWithHandle("bh_holder", Self.second)
            let student = try await birdWithHandle("bh_unique", Self.first)

            #expect(try await AvatarStore.hatch(for: student, term: try hatchTerm(), on: app.db))

            let handle = try #require(try await stored(student).avatarHandle)
            #expect(handle != Self.second)
            #expect(try await stored(holder).avatarHandle == Self.second)
        }
    }

    @Test func goingBackRestoresTheOldHandleWhileItIsFree() async throws {
        try await withApp(app) { _ in
            let student = try await birdWithHandle("bh_back", Self.first)
            #expect(try await AvatarStore.hatch(for: student, term: try hatchTerm(), on: app.db))

            #expect(try await AvatarStore.restorePreviousBird(for: student, on: app.db))

            let restored = try await stored(student)
            #expect(restored.avatarHandle == Self.first)
            #expect(restored.avatarPreviousHandle == nil)
        }
    }

    /// Another bird took the old handle after the hatch, so the bird keeps the
    /// handle from the hatch; two birds never share one.
    @Test func goingBackKeepsTheNewHandleWhenAnotherBirdHasTakenTheOldOne() async throws {
        try await withApp(app) { _ in
            let student = try await birdWithHandle("bh_taken", Self.first)
            #expect(try await AvatarStore.hatch(for: student, term: try hatchTerm(), on: app.db))
            let fromHatch = try #require(try await stored(student).avatarHandle)
            _ = try await birdWithHandle("bh_taker", Self.first)

            #expect(try await AvatarStore.restorePreviousBird(for: student, on: app.db))

            let restored = try await stored(student)
            #expect(restored.avatarHandle == fromHatch)
            #expect(restored.avatarPreviousHandle == nil)
        }
    }

    /// Staff appear under their own name, so a staff bird has no handle, and
    /// a hatch does not give it one.
    @Test func aHatchGivesABirdWithNoHandleNone() async throws {
        try await withApp(app) { _ in
            let staff = try await birdWithHandle("bh_staff", nil)

            #expect(try await AvatarStore.hatch(for: staff, term: try hatchTerm(), on: app.db))

            let hatched = try await stored(staff)
            #expect(hatched.avatarHandle == nil)
            #expect(hatched.avatarPreviousHandle == nil)
        }
    }

    // MARK: - The data export

    @Test func theDataExportCarriesTheHandleAndThePreviousHandle() async throws {
        try await withApp(app) { _ in
            let student = try await birdWithHandle("bh_export", Self.first)
            #expect(try await AvatarStore.hatch(for: student, term: try hatchTerm(), on: app.db))
            let hatched = try await stored(student)

            let content = try await gatherDataExportContent(for: hatched, on: app.db)

            #expect(content.profile.avatarHandle == hatched.avatarHandle)
            #expect(content.profile.previousAvatarHandle == Self.first)
        }
    }
}
