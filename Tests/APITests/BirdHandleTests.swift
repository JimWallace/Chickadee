// Tests/APITests/BirdHandleTests.swift
//
// The handle names the bird (docs/student-avatars.md §3). `MoveHandlesToBirds`
// moves each student's handle from their newest course to the bird; a hatch
// gives the bird a new handle, unique across the deployment; a go back gives
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

    private func course(_ code: String, _ term: AcademicTerm?) async throws -> APICourse {
        let course = APICourse(code: code, name: "Course \(code)", term: term)
        try await course.save(on: app.db)
        return course
    }

    /// Enrolls `user` in `course` with the per-course handle the enrollment
    /// held before the move.
    private func enroll(_ user: APIUser, in course: APICourse, handle: String) async throws {
        let enrollment = APICourseEnrollment(userID: try user.requireID(), courseID: try course.requireID())
        enrollment.legacyAvatarHandle = handle
        try await enrollment.save(on: app.db)
    }

    /// A student with a stored bird and `handle`.
    private func birdWithHandle(_ username: String, _ handle: String?) async throws -> APIUser {
        let user = try await makeTestStudent(on: app, username: username)
        _ = try await AvatarStore.ensureSpec(for: user, on: app.db)
        user.avatarHandle = handle
        try await user.save(on: app.db)
        return user
    }

    // MARK: - The move

    @Test func theMoveGivesEachBirdTheHandleOfItsNewestCourse() async throws {
        try await withApp(app) { _ in
            let fall = try await course("BH100", AcademicTerm(year: 2026, season: .fall))
            let winter = try await course("BH100", AcademicTerm(year: 2027, season: .winter))
            let student = try await makeTestStudent(on: app, username: "bh_newest")
            try await enroll(student, in: fall, handle: Self.first)
            try await enroll(student, in: winter, handle: Self.second)

            try await MoveHandlesToBirds().prepare(on: app.db)

            #expect(try await stored(student).avatarHandle == Self.second)
        }
    }

    /// Handles were unique per course, so two students can share one. The
    /// older account keeps it, and the newer one draws a handle no bird holds.
    @Test func theOlderAccountKeepsASharedHandleAndTheNewerDrawsAnother() async throws {
        try await withApp(app) { _ in
            let one = try await course("BH201", Self.term)
            let other = try await course("BH202", Self.term)
            let older = try await makeTestStudent(on: app, username: "bh_older")
            let newer = try await makeTestStudent(on: app, username: "bh_newer")
            try await APIUser.query(on: app.db).filter(\.$id == older.requireID())
                .set(\.$createdAt, to: Date(timeIntervalSince1970: 1_000)).update()
            try await APIUser.query(on: app.db).filter(\.$id == newer.requireID())
                .set(\.$createdAt, to: Date(timeIntervalSince1970: 2_000)).update()
            try await enroll(newer, in: one, handle: Self.first)
            try await enroll(older, in: other, handle: Self.first)

            try await MoveHandlesToBirds().prepare(on: app.db)

            #expect(try await stored(older).avatarHandle == Self.first)
            let drawn = try #require(try await stored(newer).avatarHandle)
            #expect(drawn != Self.first)
            #expect(AvatarHandle.allHandles.contains(drawn))
        }
    }

    @Test func theMoveLeavesABirdThatAlreadyHasAHandleAsItIs() async throws {
        try await withApp(app) { _ in
            let course = try await course("BH300", Self.term)
            let student = try await birdWithHandle("bh_kept", Self.second)
            try await enroll(student, in: course, handle: Self.first)

            try await MoveHandlesToBirds().prepare(on: app.db)

            #expect(try await stored(student).avatarHandle == Self.second)
        }
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
