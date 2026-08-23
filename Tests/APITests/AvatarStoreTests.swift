// Tests/APITests/AvatarStoreTests.swift
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

            let reloaded = try #require(
                try await APICourseEnrollment.find(enrollment.id, on: app.db))
            #expect(reloaded.avatarHandle == handle)
            #expect(try await AvatarStore.ensureHandle(for: reloaded, on: app.db) == handle)
        }
    }

    /// The whole point of the per-course scope: two students in one course can
    /// never be shown the same name.
    @Test func handlesAreDistinctWithinACourse() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "AVH2")
            let courseID = try course.requireID()
            var handles: Set<String> = []
            for index in 0..<12 {
                let user = try await makeTestStudent(on: app, username: "av_many_\(index)")
                let enrollment = try await makeTestEnrollment(
                    on: app, userID: try user.requireID(), courseID: courseID)
                let handle = try #require(
                    try await AvatarStore.ensureHandle(for: enrollment, on: app.db))
                #expect(!handles.contains(handle), "\(handle) issued twice in one course")
                handles.insert(handle)
            }
            #expect(handles.count == 12)
        }
    }

    /// Uniqueness is scoped to the course, so the same handle may legitimately
    /// exist in another one — and a student's two enrollments are independent.
    @Test func handlesAreScopedToOneCourse() async throws {
        try await withApp(app) { _ in
            let first = try await makeTestCourse(on: app, code: "AVH3")
            let second = try await makeTestCourse(on: app, code: "AVH4")
            let user = try await makeTestStudent(on: app, username: "av_two_courses")
            let userID = try user.requireID()

            let a = try await makeTestEnrollment(
                on: app, userID: userID, courseID: try first.requireID())
            let b = try await makeTestEnrollment(
                on: app, userID: userID, courseID: try second.requireID())
            let handleA = try #require(try await AvatarStore.ensureHandle(for: a, on: app.db))
            let handleB = try #require(try await AvatarStore.ensureHandle(for: b, on: app.db))
            #expect(AvatarHandle.isWellFormed(handleA))
            #expect(AvatarHandle.isWellFormed(handleB))
            // Independent draws: neither row may carry the other's value.
            let storedA = try await APICourseEnrollment.find(a.id, on: app.db)?.avatarHandle
            let storedB = try await APICourseEnrollment.find(b.id, on: app.db)?.avatarHandle
            #expect(storedA == handleA)
            #expect(storedB == handleB)
        }
    }

    /// A handle from an older, wider word list stops being current when a word
    /// leaves the list: it is replaced rather than shown.
    @Test func handleOutsideTheCurrentListsIsReplaced() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "AVH5")
            let user = try await makeTestStudent(on: app, username: "av_stale")
            let enrollment = try await makeTestEnrollment(
                on: app, userID: try user.requireID(), courseID: try course.requireID())
            enrollment.avatarHandle = "Sneaky Cedar"
            try await enrollment.save(on: app.db)

            let handle = try #require(
                try await AvatarStore.ensureHandle(for: enrollment, on: app.db))
            #expect(handle != "Sneaky Cedar")
            #expect(AvatarHandle.isWellFormed(handle))
        }
    }
}
