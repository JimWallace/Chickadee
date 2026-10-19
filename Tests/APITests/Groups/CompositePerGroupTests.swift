// Tests/APITests/Groups/CompositePerGroupTests.swift
//
// A class composite run once per lab group (docs/lab-groups.md, slice 4a):
// each group deals its own slots, so two groups hold the same slot numbers; a
// student is dealt in the group of the session they play in, and a student
// with no session is dealt nothing; a contribution fills the image of the
// group whose pool dealt its slot; and a per-group board with no group shows
// no image.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class CompositePerGroupTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-composite-groups")
    }

    private struct Fixture {
        let setup: APITestSetup
        let assignment: APIAssignment
        let assignmentID: UUID
        let labA: UUID
        let labB: UUID
        let ada: UUID
        let ben: UUID
        let alan: UUID
        let grace: UUID
    }

    private let setupID = "cpg_setup"
    private let spec = CompositeSpec(
        compositor: .tile, layout: .grid(columns: 3, rows: 2),
        contribution: CompositeContributionShape(width: 2, height: 1, frames: 1, format: .gray8),
        dealOrder: .rowMajor)

    /// A per-group composite with ada and ben in Lab 101, alan in Lab 102 and
    /// grace in no group.
    private func fixture() async throws -> Fixture {
        let course = try await makeTestCourse(on: app, code: "CPG1", mode: .closed)
        let courseID = try course.requireID()
        let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
        let labA = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db).requireID()
        let labB = try await CourseGroupStore.addGroup(named: "Lab 102", to: set, on: app.db).requireID()
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "tile.py")], language: .python,
            activity: ClassActivity(kind: .classComposite, composite: spec, runsPerGroup: true))
        let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
        let setup = try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: manifest)
        let assignment = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
        var students: [UUID] = []
        for (name, group) in [("cpg_ada", labA), ("cpg_ben", labA), ("cpg_alan", labB), ("cpg_grace", nil)] {
            let id = try await makeTestStudent(on: app, username: name).requireID()
            try await makeTestEnrollment(on: app, userID: id, courseID: courseID)
            if let group {
                try await CourseGroupStore.setMembership(userID: id, groupID: group, in: set, on: app.db)
            }
            students.append(id)
        }
        return Fixture(
            setup: setup, assignment: assignment, assignmentID: try assignment.requireID(), labA: labA, labB: labB,
            ada: students[0], ben: students[1], alan: students[2], grace: students[3])
    }

    /// Opens the group's session, unless it is open, and joins `userID`.
    private func join(_ f: Fixture, group: UUID, userID: UUID) async throws {
        let session = try await ActivitySessionStore.open(
            assignmentID: f.assignmentID, groupID: group, by: nil, now: Date().addingTimeInterval(-60), on: app.db)
        let joinedAt = Date().addingTimeInterval(-30)
        try await ActivitySessionStore.join(
            code: ActivitySessionCode.code(secret: session.codeSecret, at: joinedAt), userID: userID,
            now: joinedAt, on: app.db)
    }

    private func open(_ f: Fixture, _ userID: UUID) async {
        await CompositeSlots.dealOnOpen(setup: f.setup, assignment: f.assignment, userID: userID, on: app.db)
    }

    private func dealt(_ f: Fixture, _ userID: UUID) async throws -> (pool: CompositePool, slot: Int)? {
        try await CompositePool.dealtSlot(assignmentID: f.assignmentID, userID: userID, on: app.db)
    }

    @Test func twoGroupsAreDealtTheSameSlotNumbers() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            try await join(f, group: f.labA, userID: f.ada)
            try await join(f, group: f.labA, userID: f.ben)
            try await join(f, group: f.labB, userID: f.alan)
            await open(f, f.ada)
            await open(f, f.ben)
            await open(f, f.alan)

            let ada = try #require(try await dealt(f, f.ada))
            let ben = try #require(try await dealt(f, f.ben))
            let alan = try #require(try await dealt(f, f.alan))
            #expect(ada.pool == .group(assignmentID: f.assignmentID, groupID: f.labA))
            #expect(alan.pool == .group(assignmentID: f.assignmentID, groupID: f.labB))
            #expect(ada.slot == 0)
            #expect(ben.slot == 1)
            #expect(alan.slot == 0, "Lab 102 deals from its own pool")
            #expect(try await APICompositeSlot.query(on: app.db).count() == 0, "no whole-class slot")

            // A slot does not change: opening again keeps it.
            await open(f, f.ada)
            #expect(try await dealt(f, f.ada)?.slot == 0)
        }
    }

    @Test func aStudentIsDealtInTheGroupOfTheirSessionAndOnlyThen() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            // grace is in no group and joins Lab 102's session.
            try await join(f, group: f.labB, userID: f.grace)
            await open(f, f.grace)
            #expect(try await dealt(f, f.grace)?.pool == .group(assignmentID: f.assignmentID, groupID: f.labB))

            // ben never joined: opening deals nothing, and grading renders
            // slot 0 and deals nothing.
            await open(f, f.ben)
            #expect(try await dealt(f, f.ben) == nil)
            let manifest = try #require(f.setup.decodedManifest())
            let inputs = await CompositeSlots.gradingInputs(
                manifest: manifest, courseID: f.setup.courseID, assignmentID: f.assignmentID, userID: f.ben,
                usesReferenceSlot: false, on: app.db)
            #expect(inputs?[CompositeSpec.slotInputName] == "0")
            #expect(try await dealt(f, f.ben) == nil)
        }
    }

    @Test func aContributionFillsTheImageOfItsGroup() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            try await join(f, group: f.labA, userID: f.ada)
            await open(f, f.ada)
            let submission = try await makeTestSubmission(on: app, id: "cpg_s1", setupID: setupID, userID: f.ada)
            let outcome = TestOutcome(
                testName: "tile.py", testClass: nil, tier: .pub, status: .pass, shortResult: "", longResult: nil,
                composite: CompositeContribution(
                    width: 2, height: 1, frames: 1, format: .gray8, data: Data([1, 2]).base64EncodedString()),
                executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: true)
            let collection = TestOutcomeCollection(
                submissionID: "cpg_s1", testSetupID: setupID, attemptNumber: 1, buildStatus: .passed,
                compilerOutput: nil, outcomes: [outcome], totalTests: 1, passCount: 1, failCount: 0, errorCount: 0,
                timeoutCount: 0, executionTimeMs: 1, runnerVersion: "test", timestamp: Date())
            let stored = try await CompositeContributions.record(
                submission: submission, collection: collection, on: app.db)
            #expect(stored == .stored(slot: 0, passed: true))
            let row = try #require(try await APICompositeContribution.query(on: app.db).first())
            #expect(row.groupID == f.labA)

            func complete(_ group: UUID?) async throws -> Int {
                try await CompositeSnapshot.build(
                    .init(
                        assignmentID: f.assignmentID, testSetupID: setupID, courseID: f.setup.courseID, spec: spec,
                        groupID: group),
                    since: .max, onlyUserID: nil, includeOwners: false, on: app.db
                ).complete
            }
            #expect(try await complete(f.labA) == 1)
            #expect(try await complete(f.labB) == 0, "Lab 102's image is its own")
            #expect(try await complete(nil) == 0, "no whole-class image")
            #expect(
                try await APIClassItemCoverage.query(on: app.db).count() == 0,
                "a lab's tile covers no class item before slice 5")
        }
    }

    @Test func aPerGroupBoardWithNoGroupShowsNoImage() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            let activity = try #require(f.setup.decodedManifest()?.activity)
            #expect(
                try await CompositeBoardPresentation.build(
                    setup: f.setup, activity: activity, assignment: f.assignment, on: app.db) == nil)
            let board = try #require(
                try await CompositeBoardPresentation.build(
                    setup: f.setup, activity: activity, assignment: f.assignment, groupID: f.labA, on: app.db))
            #expect(board.stage.snapshotURL?.contains("group=\(f.labA.uuidString)") == true)
        }
    }
}
