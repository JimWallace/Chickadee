// Tests/APITests/Gamification/CompositeViewTests.swift
//
// The class-composite view (docs/class-composite.md, slice 5): the snapshot's
// slot states and pixels, the `since` cursor, the JSON endpoint with its ETag
// and its student filter, the stage on the leaderboard page and in present
// mode, and the student's own tile on the result page.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct CompositeViewTests {

    private let shape = CompositeContributionShape(width: 2, height: 1, frames: 1, format: .gray8)
    private let pixels = Data([10, 200]).base64EncodedString()

    private func spec(showFailed: Bool = true) -> CompositeSpec {
        CompositeSpec(
            compositor: .tile, layout: .grid(columns: 2, rows: 2), contribution: shape, dealOrder: .rowMajor,
            showFailed: showFailed)
    }

    private func manifest(_ spec: CompositeSpec) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "tile.py")], language: .python,
            activity: ClassActivity(kind: .classComposite, composite: spec))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    private struct Fixture {
        let setupID: String
        let assignmentID: UUID
        let courseID: UUID
    }

    private func fixture(_ spec: CompositeSpec, on app: Application) async throws -> Fixture {
        try await wrInsertSetup(id: "setup_view", manifest: try manifest(spec), on: app)
        let assignment = try await wrInsertAssignment(
            testSetupID: "setup_view", title: "Class GPU", isOpen: true, on: app)
        return Fixture(
            setupID: "setup_view", assignmentID: try assignment.requireID(),
            courseID: try await wrMakeCourse(on: app).requireID())
    }

    /// An enrolled student holding `slot`, with a class handle.
    private func holder(
        _ name: String, slot: Int, round: Int = 0, _ f: Fixture, on app: Application
    ) async throws
        -> UUID
    {
        let user = try await makeTestStudent(on: app, username: name)
        try await wrEnrollUser(user, on: app)
        let id = try user.requireID()
        user.avatarHandle = "Handle \(name)"
        try await user.save(on: app.db)
        try await APICompositeSlot(assignmentID: f.assignmentID, userID: id, slot: slot, round: round)
            .create(on: app.db)
        return id
    }

    private func contribute(
        _ userID: UUID, slot: Int, passed: Bool, at date: Date = Date(), _ f: Fixture, on app: Application
    ) async throws {
        let submissionID = "sub_\(UUID().uuidString.prefix(8))"
        try await wrInsertSubmission(id: submissionID, testSetupID: f.setupID, userID: userID, on: app)
        try await APICompositeContribution(
            assignmentID: f.assignmentID, userID: userID, slot: slot, submissionID: submissionID, submittedAt: date,
            contribution: CompositeContribution(width: 2, height: 1, frames: 1, format: .gray8, data: pixels),
            passed: passed
        ).create(on: app.db)
    }

    private func snapshot(
        _ f: Fixture, spec: CompositeSpec, since: Int64? = nil, onlyUserID: UUID? = nil, on app: Application
    ) async throws -> CompositeSnapshot {
        try await CompositeSnapshot.build(
            .init(assignmentID: f.assignmentID, testSetupID: f.setupID, courseID: f.courseID, spec: spec),
            since: since, onlyUserID: onlyUserID, includeOwners: true, on: app.db)
    }

    // MARK: - The snapshot

    @Test func theSnapshotCarriesEverySlotStateAndThePixels() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture(spec(), on: app)
            let a = try await holder("view_a", slot: 0, f, on: app)
            let b = try await holder("view_b", slot: 1, f, on: app)
            let c = try await holder("view_c", slot: 2, f, on: app)
            try await contribute(a, slot: 0, passed: true, f, on: app)
            try await contribute(b, slot: 1, passed: false, f, on: app)
            try await wrInsertSubmission(
                id: "sub_grading", testSetupID: f.setupID, userID: c, status: "pending", on: app)

            let snap = try await snapshot(f, spec: spec(), on: app)
            #expect(
                snap.slots == [
                    .init(slot: 0, state: "passed", rendering: false, owner: "Handle view_a"),
                    .init(slot: 1, state: "failed", rendering: false, owner: "Handle view_b"),
                    .init(slot: 2, state: "empty", rendering: true, owner: "Handle view_c"),
                ])
            #expect(snap.pixels.map(\.slot) == [0, 1])
            #expect(snap.complete == 1)
            #expect(snap.total == 4)

            let hidden = try await snapshot(f, spec: spec(showFailed: false), on: app)
            #expect(
                hidden.slots.map(\.state) == ["passed", "empty", "empty"], "with showFailed off, a failed slot is empty"
            )
            #expect(hidden.pixels.map(\.slot) == [0])
        }
    }

    /// Two students on one slot: the latest passing contribution wins over a
    /// newer failure.
    @Test func aSecondRoundSlotShowsTheLatestPass() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture(spec(), on: app)
            let first = try await holder("view_first", slot: 0, f, on: app)
            let second = try await holder("view_second", slot: 0, round: 1, f, on: app)
            try await contribute(first, slot: 0, passed: true, at: Date().addingTimeInterval(-60), f, on: app)
            try await contribute(second, slot: 0, passed: false, f, on: app)
            let snap = try await snapshot(f, spec: spec(), on: app)
            #expect(snap.slots.first?.state == "passed")
            #expect(snap.slots.first?.owner == "Handle view_first")
        }
    }

    @Test func pixelsArriveOnlyForSlotsThatChangedAfterTheCursor() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture(spec(), on: app)
            let a = try await holder("view_cur", slot: 0, f, on: app)
            try await contribute(a, slot: 0, passed: true, f, on: app)
            let first = try await snapshot(f, spec: spec(), on: app)
            let cursor = try #require(Int64(first.cursor))
            let later = try await snapshot(f, spec: spec(), since: cursor + 1, on: app)
            #expect(later.pixels.isEmpty)
            #expect(later.slots.map(\.slot) == [0], "the states come every time")
        }
    }

    // MARK: - The endpoint

    @Test func staffReadEverySlotAndAnUnchangedPollIsA304() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            try await wrEnrollUser(
                try #require(try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first()), on: app)
            let f = try await fixture(spec(), on: app)
            let a = try await holder("view_http", slot: 0, f, on: app)
            try await contribute(a, slot: 0, passed: true, f, on: app)

            var etag = ""
            try await app.asyncTest(
                .GET, "/testsetups/\(f.setupID)/composite",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    etag = res.headers.first(name: .eTag) ?? ""
                    let snap = try res.content.decode(CompositeSnapshot.self)
                    #expect(snap.slots.first?.owner == "Handle view_http")
                    #expect(snap.pixels.count == 1)
                })
            #expect(!etag.isEmpty)
            try await app.asyncTest(
                .GET, "/testsetups/\(f.setupID)/composite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    req.headers.add(name: .ifNoneMatch, value: etag)
                },
                afterResponse: { res in #expect(res.status == .notModified) })
            try await app.asyncTest(
                .GET, "/testsetups/\(f.setupID)/composite?present=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    let snap = try res.content.decode(CompositeSnapshot.self)
                    #expect(snap.slots.first?.owner == nil, "the room reads no handles")
                })
        }
    }

    @Test func aStudentReadsOnlyTheirOwnSlot() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrEnrollUser(student, on: app)
            let f = try await fixture(spec(), on: app)
            let me = try student.requireID()
            try await APICompositeSlot(assignmentID: f.assignmentID, userID: me, slot: 3, round: 0).create(on: app.db)
            try await contribute(me, slot: 3, passed: true, f, on: app)
            let other = try await holder("view_other", slot: 0, f, on: app)
            try await contribute(other, slot: 0, passed: true, f, on: app)

            try await app.asyncTest(
                .GET, "/testsetups/\(f.setupID)/composite",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let snap = try res.content.decode(CompositeSnapshot.self)
                    #expect(snap.slots.map(\.slot) == [3])
                    #expect(snap.slots.first?.owner == nil)
                    #expect(snap.pixels.map(\.slot) == [3])
                })
        }
    }

    @Test func anotherKindHasNoComposite() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let props = TestProperties(
                testSuites: [TestSuiteEntry(tier: .pub, script: "m.sh")], language: nil,
                activity: ClassActivity(kind: .bestMetric))
            let metricManifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
            try await wrInsertSetup(id: "setup_metric", manifest: metricManifest, on: app)
            try await wrInsertAssignment(testSetupID: "setup_metric", title: "Metric", isOpen: true, on: app)
            try await app.asyncTest(
                .GET, "/testsetups/setup_metric/composite",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.status == .notFound) })
        }
    }

    // MARK: - The pages

    @Test func theLeaderboardAndPresentModeDrawTheStage() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            try await wrEnrollUser(
                try #require(try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first()), on: app)
            let f = try await fixture(spec(), on: app)
            _ = try await holder("view_page", slot: 0, f, on: app)
            try await app.asyncTest(
                .GET, "/testsetups/\(f.setupID)/leaderboard",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("js-class-composite"))
                    #expect(html.contains("data-poll-url=\"/testsetups/\(f.setupID)/composite\""))
                    #expect(html.contains("data-poll-swap=\"json\""), "the canvas polls through table-poll.js")
                    #expect(html.contains("data-composite-owners=\"true\""))
                    #expect(html.contains("--composite-cols: 2; --composite-rows: 2"))
                    #expect(html.contains("/class-composite.js"))
                    #expect(html.contains("/table-poll.js"))
                    #expect(html.contains("0 of 4 tiles complete"))
                    #expect(html.contains("Slot holders (1)"))
                    #expect(html.contains("Column 1, row 1"))
                })
            try await app.asyncTest(
                .GET, "/testsetups/\(f.setupID)/leaderboard?present=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    let html = res.body.string
                    #expect(html.contains("present-composite"))
                    #expect(html.contains("data-poll-url=\"/testsetups/\(f.setupID)/composite?present=1\""))
                    #expect(html.contains("data-composite-owners=\"false\""))
                    #expect(html.contains("Tiles complete"))
                    #expect(!html.contains("on the board"))
                    #expect(!html.contains("Slot holders"), "the room reads no names")
                })
        }
    }

    @Test func theResultPageShowsTheStudentsOwnTile() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrEnrollUser(student, on: app)
            let f = try await fixture(spec(), on: app)
            let me = try student.requireID()
            try await APICompositeSlot(assignmentID: f.assignmentID, userID: me, slot: 3, round: 0).create(on: app.db)
            try await wrInsertSubmission(id: "sub_tile", testSetupID: f.setupID, userID: me, on: app)
            let outcome = TestOutcome(
                testName: "tile", testClass: nil, tier: .pub, status: .pass, shortResult: "passed", longResult: nil,
                composite: CompositeContribution(width: 2, height: 1, frames: 1, format: .gray8, data: pixels),
                executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: true)
            try await wrInsertResult(submissionID: "sub_tile", outcomes: [outcome], on: app)

            try await app.asyncTest(
                .GET, "/submissions/sub_tile",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("Your tile: column 2, row 2"))
                    #expect(html.contains("data-composite-pixels=\"\(pixels)\""))
                    #expect(html.contains("Passed"))
                    #expect(!html.contains("data-poll-url"), "the own tile does not poll")
                })
        }
    }
}
