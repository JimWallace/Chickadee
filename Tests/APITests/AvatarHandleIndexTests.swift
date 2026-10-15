// Tests/APITests/AvatarHandleIndexTests.swift
//
// A handle names the bird, so it is unique across the deployment:
// `idx_users_avatar_handle`, a partial unique index that `AddUserAvatarHandle`
// creates by raw SQL. The lost-race branches in `AvatarStore` run only when
// that index refuses a write, so a migration that dropped the index would pass
// every other test (#1755). These name the index by its effect.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AvatarHandleIndexTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-handle-index")
    }

    /// A handle from the lists, so the store treats it as a real one.
    private static let handle = "\(AvatarHandle.scienceWords[0]) \(AvatarHandle.agents[0])"

    /// Every handle on the lists except `free`: a stale taken set whose only
    /// gap is a handle another bird already holds.
    private static func everyHandle(except free: String) -> Set<String> {
        var all = AvatarHandle.allHandles
        all.remove(free)
        return all
    }

    @Test func theIndexRefusesOneHandleOnTwoBirds() async throws {
        try await withApp(app) { _ in
            let first = try await makeTestStudent(on: app, username: "hix_first")
            let second = try await makeTestStudent(on: app, username: "hix_second")
            first.avatarHandle = Self.handle
            try await first.save(on: app.db)
            second.avatarHandle = Self.handle
            await #expect(throws: (any Error).self) {
                try await second.save(on: app.db)
            }
            #expect(try await APIUser.find(second.id, on: app.db)?.avatarHandle == nil)
        }
    }

    /// Many birds have no handle yet; the partial index lets them all be NULL.
    @Test func theIndexAllowsManyBirdsWithNoHandle() async throws {
        try await withApp(app) { _ in
            let one = try await makeTestStudent(on: app, username: "hix_none_one")
            let other = try await makeTestStudent(on: app, username: "hix_none_other")
            try await one.save(on: app.db)
            try await other.save(on: app.db)
            #expect(try await APIUser.find(other.id, on: app.db)?.avatarHandle == nil)
        }
    }

    /// The lost-race branch of `ensureHandle`: the taken set it was given is
    /// stale and leaves free only a handle another bird already holds, so the
    /// draw lands on it, the index refuses the save, and the bird stays
    /// unnamed for the next page load to try again.
    @Test func aLostRaceOnTheIndexLeavesTheBirdUnnamed() async throws {
        try await withApp(app) { _ in
            let holder = try await makeTestStudent(on: app, username: "hix_holder")
            holder.avatarHandle = Self.handle
            try await holder.save(on: app.db)

            let loser = try await makeTestStudent(on: app, username: "hix_loser")
            let drawn = try await AvatarStore.ensureHandle(
                for: loser, taken: Self.everyHandle(except: Self.handle), on: app.db)
            #expect(drawn == nil)
            #expect(loser.avatarHandle == nil)
            #expect(try await APIUser.find(loser.id, on: app.db)?.avatarHandle == nil)
            #expect(try await APIUser.find(holder.id, on: app.db)?.avatarHandle == Self.handle)
        }
    }

    /// The lost-race branch of `redrawHandle`: the only handle its stale set
    /// leaves free is another bird's, so the index refuses the save, the retry
    /// finds nothing left, and the old handle stays (#2255).
    @Test func aLostRaceOnARedrawKeepsTheOldHandle() async throws {
        try await withApp(app) { _ in
            let holder = try await makeTestStudent(on: app, username: "hix_redraw_holder")
            holder.avatarHandle = Self.handle
            try await holder.save(on: app.db)
            let redrawn = try await makeTestStudent(on: app, username: "hix_redrawn")
            redrawn.avatarHandle = "Quiet Cedar"
            try await redrawn.save(on: app.db)

            let handle = try await AvatarStore.redrawHandle(
                for: redrawn, taken: Self.everyHandle(except: Self.handle), on: app.db)
            #expect(handle == nil)
            #expect(redrawn.avatarHandle == "Quiet Cedar")
            #expect(try await APIUser.find(redrawn.id, on: app.db)?.avatarHandle == "Quiet Cedar")
        }
    }

    /// A save that fails for any other reason is thrown, not read as an
    /// exhausted pool. Here the row takes another user's URL token, so a
    /// different unique index refuses the write (#2255).
    @Test func aRedrawThatFailsForAnotherReasonThrows() async throws {
        try await withApp(app) { _ in
            let other = try await makeTestStudent(on: app, username: "hix_token_owner")
            let broken = try await makeTestStudent(on: app, username: "hix_broken")
            broken.avatarHandle = "Quiet Cedar"
            try await broken.save(on: app.db)
            broken.urlToken = other.urlToken

            await #expect(throws: (any Error).self) {
                try await AvatarStore.redrawHandle(for: broken, taken: [], on: app.db)
            }
            #expect(broken.avatarHandle == "Quiet Cedar")
        }
    }
}
