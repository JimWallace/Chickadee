// Tests/APITests/Groups/CompositeSparesPerGroupTests.swift
//
// The spares of a class composite run once per lab group (docs/lab-groups.md,
// slice 4b): a spare fills a hole in the image of the student's own group
// only and covers no class item; a student fills holes only while they play
// in their group's open session; a failed spare leaves a hole in its own lab,
// and two labs can each hold a spare in one slot; Remove deletes the
// student's finished spares in the group with their jobs and keeps one still
// grading; and deleting a student removes their lab spare jobs.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct CompositeSparesPerGroupTests {

    private let setupID = "cspg_setup"
    private let ownPixels = Data([10, 200]).base64EncodedString()
    private let sparePixels = Data([60, 60]).base64EncodedString()
    private let spec = CompositeSpec(
        compositor: .tile, layout: .grid(columns: 2, rows: 2),
        contribution: CompositeContributionShape(width: 2, height: 1, frames: 1, format: .gray8),
        dealOrder: .rowMajor)

    private struct Fixture {
        let setup: APITestSetup
        let assignment: APIAssignment
        let assignmentID: UUID
        let courseID: UUID
        let labA: UUID
        let labB: UUID
    }

    private func fixture(on app: Application) async throws -> Fixture {
        let courseID = try await wrMakeCourse(on: app).requireID()
        let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
        let labA = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db).requireID()
        let labB = try await CourseGroupStore.addGroup(named: "Lab 102", to: set, on: app.db).requireID()
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "tile.py")], language: .python,
            activity: ClassActivity(kind: .classComposite, composite: spec, runsPerGroup: true))
        let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
        let setup = try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: manifest)
        let assignment = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
        return Fixture(
            setup: setup, assignment: assignment, assignmentID: try assignment.requireID(), courseID: courseID,
            labA: labA, labB: labB)
    }

    /// An enrolled student who joins `group`'s session, is dealt a slot in
    /// it, and has a tile there that passed.
    private func student(_ name: String, in group: UUID, _ f: Fixture, on app: Application) async throws -> UUID {
        let user = try await makeTestStudent(on: app, username: name)
        try await wrEnrollUser(user, on: app)
        let id = try user.requireID()
        let session = try await ActivitySessionStore.open(
            assignmentID: f.assignmentID, groupID: group, by: nil, now: Date().addingTimeInterval(-60), on: app.db)
        let joinedAt = Date().addingTimeInterval(-30)
        try await ActivitySessionStore.join(
            code: ActivitySessionCode.code(secret: session.codeSecret, at: joinedAt), userID: id, now: joinedAt,
            on: app.db)
        await CompositeSlots.dealOnOpen(setup: f.setup, assignment: f.assignment, userID: id, on: app.db)
        let slot = try #require(try await CompositePool.dealtSlot(assignmentID: f.assignmentID, userID: id, on: app.db))
        let submissionID = "sub_\(name)"
        try await wrInsertSubmission(id: submissionID, testSetupID: setupID, userID: id, on: app)
        try "print(1)\n".write(
            toFile: app.submissionsDirectory + "\(submissionID).py", atomically: true, encoding: .utf8)
        let row = APICompositeContribution(
            assignmentID: f.assignmentID, userID: id, slot: slot.slot, submissionID: submissionID,
            submittedAt: Date(),
            contribution: CompositeContribution(width: 2, height: 1, frames: 1, format: .gray8, data: ownPixels),
            passed: true)
        row.groupID = group
        try await row.create(on: app.db)
        return id
    }

    private func request(_ f: Fixture, for userID: UUID, on app: Application) async throws -> Int {
        try await CompositeSpares.request(
            assignment: f.assignment, setup: f.setup, userID: userID, app: app, on: app.db)
    }

    private func spare(
        _ f: Fixture, group: UUID, slot: Int, on app: Application
    ) async throws
        -> APIGroupCompositeSpare
    {
        try #require(
            try await APIGroupCompositeSpare.query(on: app.db)
                .filter(\.$assignmentID == f.assignmentID).filter(\.$groupID == group).filter(\.$slot == slot)
                .first())
    }

    private func collection(
        _ submissionID: String, status: TestStatus = .pass, data: String
    ) -> TestOutcomeCollection {
        let passed = status == .pass
        let outcome = TestOutcome(
            testName: "tile.py", testClass: nil, tier: .pub, status: status, shortResult: "", longResult: nil,
            composite: CompositeContribution(width: 2, height: 1, frames: 1, format: .gray8, data: data),
            executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: passed)
        return TestOutcomeCollection(
            submissionID: submissionID, testSetupID: setupID, attemptNumber: 1, buildStatus: .passed,
            compilerOutput: nil, outcomes: [outcome], totalTests: 1, passCount: passed ? 1 : 0,
            failCount: passed ? 0 : 1, errorCount: 0, timeoutCount: 0, executionTimeMs: 1, runnerVersion: "test",
            timestamp: Date())
    }

    /// Records the result of the group's spare in `slot`.
    private func finish(
        _ f: Fixture, group: UUID, slot: Int, status: TestStatus = .pass, on app: Application
    ) async throws {
        let row = try await spare(f, group: group, slot: slot, on: app)
        let job = try #require(try await APISubmission.find(row.submissionID, on: app.db))
        try await CompositeSpares.record(
            submission: job, collection: collection(row.submissionID, status: status, data: sparePixels), on: app.db)
    }

    private func complete(_ f: Fixture, group: UUID?, on app: Application) async throws -> Int {
        try await CompositeSnapshot.build(
            .init(
                assignmentID: f.assignmentID, testSetupID: setupID, courseID: f.courseID, spec: spec, groupID: group),
            since: nil, onlyUserID: nil, includeOwners: false, on: app.db
        ).complete
    }

    @Test func aSpareFillsAHoleInItsOwnGroupOnly() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture(on: app)
            let ada = try await student("cspg_ada", in: f.labA, f, on: app)
            _ = try await student("cspg_alan", in: f.labB, f, on: app)
            let labA = CompositePool.group(assignmentID: f.assignmentID, groupID: f.labA)
            let labB = CompositePool.group(assignmentID: f.assignmentID, groupID: f.labB)

            #expect(try await request(f, for: ada, on: app) == 1)
            let row = try await spare(f, group: f.labA, slot: 1, on: app)
            #expect(row.userID == ada)
            #expect(try await APICompositeSpare.query(on: app.db).count() == 0, "no whole-class spare")
            #expect(try await CompositeSpares.holes(in: labA, spec: spec, on: app.db) == [2, 3])
            #expect(try await CompositeSpares.holes(in: labB, spec: spec, on: app.db) == [1, 2, 3])

            let job = try #require(try await APISubmission.find(row.submissionID, on: app.db))
            let manifest = try #require(f.setup.decodedManifest())
            let inputs = await CompositeSlots.jobInputs(
                manifest: manifest, courseID: f.courseID, assignmentID: f.assignmentID, submission: job, on: app.db)
            #expect(inputs == spec.inputs(forSlot: 1).mapValues(AssignmentLanguage.python.literal))

            try await CompositeSpares.record(
                submission: job, collection: collection(row.submissionID, data: sparePixels), on: app.db)
            #expect(
                try await CompositeSpares.status(in: labA, userID: ada, on: app.db)
                    == [CompositeSpares.Status(slot: 1, grading: false, passed: true)])
            #expect(try await complete(f, group: f.labA, on: app) == 2)
            #expect(try await complete(f, group: f.labB, on: app) == 1, "Lab 102's image is its own")
            #expect(try await complete(f, group: nil, on: app) == 0)
            #expect(
                try await APIClassItemCoverage.query(on: app.db).count() == 0,
                "a lab's spare covers no class item before slice 5")
        }
    }

    @Test func aStudentFillsHolesOnlyWhileTheirSessionIsOpen() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture(on: app)
            let ada = try await student("cspg_ada", in: f.labA, f, on: app)
            let viewer = try #require(try await APIUser.find(ada, on: app.db))
            let submission = try #require(try await APISubmission.find("sub_cspg_ada", on: app.db))
            let manifest = try #require(f.setup.decodedManifest())
            func spareAction() async throws -> String? {
                try await CompositeTilePanel.make(
                    for: submission, collection("sub_cspg_ada", data: ownPixels), manifest, f.assignment,
                    viewer: viewer, on: app.db)?.spareAction
            }
            #expect(try await spareAction() == "/testsetups/\(setupID)/composite/spare")

            let session = try #require(
                try await ActivitySessionStore.session(assignmentID: f.assignmentID, groupID: f.labA, on: app.db))
            try await ActivitySessionStore.close(session, on: app.db)
            #expect(try await spareAction() == nil)
            await #expect(throws: CompositeSpares.RequestError.sessionClosed) {
                _ = try await request(f, for: ada, on: app)
            }
        }
    }

    @Test func aFailedSpareIsReplacedInItsLabAndTwoLabsHoldASpareInOneSlot() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture(on: app)
            let ada = try await student("cspg_ada", in: f.labA, f, on: app)
            let ben = try await student("cspg_ben", in: f.labA, f, on: app)
            let alan = try await student("cspg_alan", in: f.labB, f, on: app)

            #expect(try await request(f, for: ada, on: app) == 2)
            let failed = try await spare(f, group: f.labA, slot: 2, on: app).submissionID
            try await finish(f, group: f.labA, slot: 2, status: .fail, on: app)
            #expect(try await request(f, for: ben, on: app) == 2, "the failed spare leaves a hole for others")
            #expect(try await spare(f, group: f.labA, slot: 2, on: app).userID == ben)
            #expect(try await APISubmission.find(failed, on: app.db) == nil, "the failed job goes")

            #expect(try await request(f, for: alan, on: app) == 1)
            try await finish(f, group: f.labB, slot: 1, on: app)
            #expect(try await request(f, for: alan, on: app) == 2, "Lab 102 fills its own slot 2")
            #expect(try await APIGroupCompositeSpare.query(on: app.db).filter(\.$slot == 2).count() == 2)
        }
    }

    @Test func removeDeletesTheStudentsFinishedSparesInTheGroup() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture(on: app)
            let ada = try await student("cspg_ada", in: f.labA, f, on: app)
            #expect(try await request(f, for: ada, on: app) == 1)
            let finished = try await spare(f, group: f.labA, slot: 1, on: app).submissionID
            try await finish(f, group: f.labA, slot: 1, on: app)
            #expect(try await request(f, for: ada, on: app) == 2)

            let session = try #require(
                try await ActivitySessionStore.session(assignmentID: f.assignmentID, groupID: f.labA, on: app.db))
            #expect(try await ActivitySessionStore.remove(userID: ada, from: session, on: app.db))
            #expect(try await APISubmission.find(finished, on: app.db) == nil, "the spare's job goes with it")
            let left = try await APIGroupCompositeSpare.query(on: app.db).all()
            #expect(left.map(\.slot) == [2], "a spare still grading stays, so the runner's report finds its job")
        }
    }

    @Test func deletingAStudentRemovesTheirLabSpareJobs() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await loginAsAdmin("cspg_admin", on: app)
            let f = try await fixture(on: app)
            let ada = try await student("cspg_ada", in: f.labA, f, on: app)
            let slot = try await request(f, for: ada, on: app)
            let job = try #require(
                try await APISubmission.find(
                    try await spare(f, group: f.labA, slot: slot, on: app).submissionID, on: app.db))

            let (token, boundCookie) = try await csrfFields(for: "/admin", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/admin/users/\(ada.uuidString)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })
            #expect(try await APIUser.find(ada, on: app.db) == nil)
            #expect(try await APISubmission.find(try job.requireID(), on: app.db) == nil)
            #expect(!FileManager.default.fileExists(atPath: job.zipPath), "the copy of their code goes")
        }
    }
}
