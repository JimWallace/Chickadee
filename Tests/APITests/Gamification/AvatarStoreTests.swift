// Tests/APITests/Gamification/AvatarStoreTests.swift
//
// First-use materialization for the avatar spec and the per-course handle.
// The property that matters is that both are drawn ONCE and then stable: a
// student's bird and pseudonym changing between page loads would be worse than
// not having them (docs/student-avatars.md).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AvatarStoreTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-avatar")
    }

    // MARK: - Spec

    @Test func specIsDrawnOnFirstUseAndThenStable() async throws {
        try await withApp(app) { _ in
            let user = try await makeTestStudent(on: app, username: "av_spec")
            #expect(user.avatarSpecJSON == nil)

            let first = try await AvatarStore.ensureSpec(for: user, on: app.db)
            let stored = try #require(
                try await APIUser.find(user.id, on: app.db)?.avatarSpecJSON)
            #expect(AvatarStore.decode(stored) == first)

            // A second call must not redraw — a bird that changes on reload is
            // not an identity.
            let reloaded = try #require(try await APIUser.find(user.id, on: app.db))
            #expect(try await AvatarStore.ensureSpec(for: reloaded, on: app.db) == first)
        }
    }

    /// A stored spec that no longer decodes (a hand-edited row, a slot renamed)
    /// is redrawn rather than crashing the page it appears on.
    @Test func unreadableSpecIsRedrawnRatherThanThrown() async throws {
        try await withApp(app) { _ in
            let user = try await makeTestStudent(on: app, username: "av_spec_bad")
            user.avatarSpecJSON = "{\"cap\":\"chartreuse\"}"
            try await user.save(on: app.db)

            let spec = try await AvatarStore.ensureSpec(for: user, on: app.db)
            #expect(AvatarCap.allCases.contains(spec.cap))
            let stored = try #require(
                try await APIUser.find(user.id, on: app.db)?.avatarSpecJSON)
            #expect(AvatarStore.decode(stored) == spec)
        }
    }

    // MARK: - Handle

    @Test func handleIsGeneratedOnFirstUseAndThenStable() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "AVH1")
            let user = try await makeTestStudent(on: app, username: "av_handle")
            let enrollment = try await makeTestEnrollment(
                on: app, userID: try user.requireID(), courseID: try course.requireID())

            let handle = try #require(
                try await AvatarStore.ensureHandle(for: enrollment, on: app.db))
            #expect(AvatarHandle.isWellFormed(handle))

            let reloaded = try #require(try await APIUser.find(user.id, on: app.db))
            #expect(reloaded.avatarHandle == handle)
            #expect(try await AvatarStore.ensureHandle(for: reloaded, on: app.db) == handle)
        }
    }

    /// The handle names the bird, so no two birds share one, in a course or
    /// anywhere else.
    @Test func handlesAreDistinctAcrossBirds() async throws {
        try await withApp(app) { _ in
            var handles: Set<String> = []
            for index in 0..<12 {
                let user = try await makeTestStudent(on: app, username: "av_many_\(index)")
                let handle = try #require(try await AvatarStore.ensureHandle(for: user, on: app.db))
                #expect(!handles.contains(handle), "\(handle) issued twice")
                handles.insert(handle)
            }
            #expect(handles.count == 12)
        }
    }

    /// One bird, one handle: a student's two enrollments show the same name.
    @Test func aStudentHasOneHandleInEveryCourse() async throws {
        try await withApp(app) { _ in
            let first = try await makeTestCourse(on: app, code: "AVH3")
            let second = try await makeTestCourse(on: app, code: "AVH4")
            let user = try await makeTestStudent(on: app, username: "av_two_courses")
            let userID = try user.requireID()

            let a = try await makeTestEnrollment(on: app, userID: userID, courseID: try first.requireID())
            let b = try await makeTestEnrollment(on: app, userID: userID, courseID: try second.requireID())
            let handleA = try #require(try await AvatarStore.ensureHandle(for: a, on: app.db))
            let handleB = try #require(try await AvatarStore.ensureHandle(for: b, on: app.db))
            #expect(handleA == handleB)
            #expect(try await APIUser.find(userID, on: app.db)?.avatarHandle == handleA)
        }
    }

    /// A handle from an earlier word list is kept: a list change must never
    /// rename a student (docs/student-avatars.md §3).
    @Test func handleFromAnEarlierListIsKept() async throws {
        try await withApp(app) { _ in
            let user = try await makeTestStudent(on: app, username: "av_stale")
            user.avatarHandle = "Sneaky Cedar"
            try await user.save(on: app.db)

            let handle = try await AvatarStore.ensureHandle(for: user, on: app.db)
            #expect(handle == "Sneaky Cedar")
            #expect(try await APIUser.find(user.id, on: app.db)?.avatarHandle == "Sneaky Cedar")
        }
    }

    /// A stored value of the wrong form (a hand-edited row) is redrawn.
    @Test(arguments: ["sneaky cedar", "Sneaky Cedar Grove Path", "Sneaky C3dar", ""])
    func malformedHandleIsRedrawn(stored: String) async throws {
        try await withApp(app) { _ in
            let user = try await makeTestStudent(on: app, username: "av_malformed")
            user.avatarHandle = stored
            try await user.save(on: app.db)

            let handle = try #require(try await AvatarStore.ensureHandle(for: user, on: app.db))
            #expect(handle != stored)
            #expect(AvatarHandle.isWellFormed(handle))
        }
    }

    /// The staff "Give new handle" action: a fresh draw from the current lists,
    /// never the old handle and never one another bird holds.
    @Test func redrawGivesANewCurrentHandle() async throws {
        try await withApp(app) { _ in
            let other = try await makeTestStudent(on: app, username: "av_redraw_other")
            let otherHandle = try #require(try await AvatarStore.ensureHandle(for: other, on: app.db))

            let user = try await makeTestStudent(on: app, username: "av_redraw")
            user.avatarHandle = "Quiet Cedar"
            try await user.save(on: app.db)

            let handle = try #require(try await AvatarStore.redrawHandle(for: user, on: app.db))
            #expect(handle != "Quiet Cedar")
            #expect(handle != otherHandle)
            #expect(AvatarHandle.isWellFormed(handle))
            #expect(try await APIUser.find(user.id, on: app.db)?.avatarHandle == handle)
        }
    }

}
