// Tests/APITests/Groups/CompositeGalleryTests.swift
//
// The gallery of every lab's image of a class composite run once per lab
// group (docs/lab-groups.md, slice 4c): a lab shows in the group set's order
// once its session has ended, a lab whose session is open or never opened
// does not, each stage reads its own lab's image and stops polling at the
// close, two animated stages get two slider ids, and only staff see it.

import Core
import Elementary
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct CompositeGalleryTests {

    private let setupID = "cgal_setup"

    private func spec(frames: Int = 1) -> CompositeSpec {
        CompositeSpec(
            compositor: .tile, layout: .grid(columns: 2, rows: 2),
            contribution: CompositeContributionShape(width: 2, height: 1, frames: frames, format: .gray8),
            dealOrder: .rowMajor)
    }

    private struct Fixture {
        let setup: APITestSetup
        let assignment: APIAssignment
        let assignmentID: UUID
        let labs: [UUID]
    }

    /// A per-group composite in a course with Lab 101, Lab 102 and Lab 103.
    private func fixture(runsPerGroup: Bool = true, on app: Application) async throws -> Fixture {
        let courseID = try await wrMakeCourse(on: app).requireID()
        let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
        var labs: [UUID] = []
        for name in ["Lab 101", "Lab 102", "Lab 103"] {
            labs.append(try await CourseGroupStore.addGroup(named: name, to: set, on: app.db).requireID())
        }
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "tile.py")], language: .python,
            activity: ClassActivity(kind: .classComposite, composite: spec(), runsPerGroup: runsPerGroup))
        let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
        let setup = try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: manifest)
        let assignment = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
        return Fixture(setup: setup, assignment: assignment, assignmentID: try assignment.requireID(), labs: labs)
    }

    /// Opens `group`'s session, and ends it unless `ended` is false.
    private func session(_ f: Fixture, group: UUID, ended: Bool = true, on app: Application) async throws {
        let session = try await ActivitySessionStore.open(
            assignmentID: f.assignmentID, groupID: group, by: nil, now: Date().addingTimeInterval(-120), on: app.db)
        if ended {
            try await ActivitySessionStore.close(session, now: Date().addingTimeInterval(-60), on: app.db)
        }
    }

    private func gallery(_ f: Fixture, on app: Application) async throws -> CompositeGalleryPresentation? {
        let activity = try #require(f.setup.decodedManifest()?.activity)
        return try await CompositeGalleryPresentation.build(
            setup: f.setup, activity: activity, assignment: f.assignment, on: app.db)
    }

    @Test func aLabShowsOnceItsSessionHasEndedInTheSetsOrder() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture(on: app)
            #expect(try await gallery(f, on: app) == nil, "no session has ended")

            try await session(f, group: f.labs[2], on: app)
            try await session(f, group: f.labs[1], ended: false, on: app)
            try await session(f, group: f.labs[0], on: app)
            let labs = try #require(try await gallery(f, on: app)).labs
            #expect(labs.map(\.name) == ["Lab 101", "Lab 103"])
            #expect(labs.map(\.progressText) == ["0 of 4 tiles complete", "0 of 4 tiles complete"])
            let first = try #require(labs.first?.stage)
            #expect(first.snapshotURL?.contains("group=\(f.labs[0].uuidString)") == true)
            #expect(!first.pollUntilISO.isEmpty, "the stage stops polling at the close")
        }
    }

    @Test func aWholeClassCompositeHasNoGallery() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture(runsPerGroup: false, on: app)
            try await session(f, group: f.labs[0], on: app)
            #expect(try await gallery(f, on: app) == nil)
        }
    }

    @Test func twoAnimatedStagesGetTwoSliderIDs() throws {
        let stage = CompositeStagePresentation.board(
            spec: spec(frames: 2), testSetupID: setupID, present: false, groupID: UUID(), pollUntilISO: "")
        let html = CompositeGallerySection(
            gallery: CompositeGalleryPresentation(labs: [
                .init(name: "Lab 101", progressText: "", stage: stage),
                .init(name: "Lab 102", progressText: "", stage: stage),
            ])
        ).render()
        #expect(html.contains("id=\"composite-scrub-0\""))
        #expect(html.contains("id=\"composite-scrub-1\""))
        #expect(!html.contains("id=\"composite-scrub\""))
    }

    @Test func onlyStaffSeeTheGallery() async throws {
        try await withWebRoutesApp { app in
            let staffCookie = try await wrLoginAsInstructor(on: app)
            try await wrEnrollUser(
                try #require(try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first()),
                on: app)
            let studentCookie = try await wrLoginAsStudent(on: app)
            try await wrEnrollUser(try await wrStudentUser(on: app), on: app)
            let f = try await fixture(on: app)
            try await session(f, group: f.labs[0], on: app)

            func page(_ cookie: String) async throws -> String {
                var body = ""
                try await app.asyncTest(
                    .GET, "/testsetups/\(setupID)/leaderboard",
                    beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                    afterResponse: { res in body = res.body.string })
                return body
            }
            #expect(try await page(staffCookie).contains("Every lab"))
            #expect(!(try await page(studentCookie).contains("Every lab")))
        }
    }
}
