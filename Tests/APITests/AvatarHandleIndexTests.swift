// Tests/APITests/AvatarHandleIndexTests.swift
//
// Per-course handle uniqueness lives in `idx_enrollments_course_handle`, a
// partial unique index that `AddAvatarIdentity` creates by raw SQL. The
// lost-race branches in `AvatarStore` run only when that index refuses a
// write, so a migration fold that dropped the index would pass every other
// test (#1755). These name the index by its effect.

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
    private static let handle = "\(AvatarHandle.adjectives[0]) \(AvatarHandle.nouns[0])"

    private func enroll(_ username: String, in courseID: UUID) async throws -> APICourseEnrollment {
        let user = try await makeTestStudent(on: app, username: username)
        return try await makeTestEnrollment(on: app, userID: try user.requireID(), courseID: courseID)
    }

    @Test func theIndexRefusesOneHandleTwiceInACourse() async throws {
        try await withApp(app) { _ in
            let courseID = try await makeTestCourse(on: app, code: "HIX1").requireID()
            let first = try await enroll("hix_first", in: courseID)
            let second = try await enroll("hix_second", in: courseID)
            first.avatarHandle = Self.handle
            try await first.save(on: app.db)
            second.avatarHandle = Self.handle
            await #expect(throws: (any Error).self) {
                try await second.save(on: app.db)
            }
            #expect(try await APICourseEnrollment.find(second.id, on: app.db)?.avatarHandle == nil)
        }
    }

    @Test func theIndexAllowsOneHandleInTwoCourses() async throws {
        try await withApp(app) { _ in
            let oneID = try await makeTestCourse(on: app, code: "HIX2A").requireID()
            let otherID = try await makeTestCourse(on: app, code: "HIX2B").requireID()
            let one = try await enroll("hix_one", in: oneID)
            let other = try await enroll("hix_other", in: otherID)
            one.avatarHandle = Self.handle
            try await one.save(on: app.db)
            other.avatarHandle = Self.handle
            try await other.save(on: app.db)
            #expect(try await APICourseEnrollment.find(other.id, on: app.db)?.avatarHandle == Self.handle)
        }
    }

    /// The lost-race branch of `ensureHandle`: the taken set it was given is
    /// stale and leaves free only a handle a classmate already holds, so the
    /// draw lands on it, the index refuses the save, and the enrollment
    /// stays unnamed for the next page load to try again.
    @Test func aLostRaceOnTheIndexLeavesTheEnrollmentUnnamed() async throws {
        try await withApp(app) { _ in
            let courseID = try await makeTestCourse(on: app, code: "HIX3").requireID()
            let holder = try await enroll("hix_holder", in: courseID)
            holder.avatarHandle = Self.handle
            try await holder.save(on: app.db)

            var stale: Set<String> = []
            for adjective in AvatarHandle.adjectives {
                for noun in AvatarHandle.nouns { stale.insert("\(adjective) \(noun)") }
            }
            stale.remove(Self.handle)

            let loser = try await enroll("hix_loser", in: courseID)
            let drawn = try await AvatarStore.ensureHandle(for: loser, taken: stale, on: app.db)
            #expect(drawn == nil)
            #expect(loser.avatarHandle == nil)
            #expect(try await APICourseEnrollment.find(loser.id, on: app.db)?.avatarHandle == nil)
            #expect(try await APICourseEnrollment.find(holder.id, on: app.db)?.avatarHandle == Self.handle)
        }
    }
}
