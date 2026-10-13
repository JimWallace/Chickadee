// Tests/APITests/CompositeContributionsTests.swift
//
// Ingesting class-composite contributions (docs/class-composite.md, slice 4):
// the payload checks, the one row for each student, the newer submission
// winning, the slot's coverage row, the shared ingest effects that both result
// paths call, and course deletion.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct CompositeContributionsTests {

    /// 2 × 1 pixels, 1 frame, gray: two bytes.
    private let shape = CompositeContributionShape(width: 2, height: 1, frames: 1, format: .gray8)
    private let twoBytes = Data([10, 200]).base64EncodedString()

    private var spec: CompositeSpec {
        CompositeSpec(
            compositor: .tile, layout: .grid(columns: 2, rows: 2), contribution: shape, dealOrder: .rowMajor)
    }

    private struct Fixture {
        let assignmentID: UUID
        let courseID: UUID
        let setupID: String
    }

    private func fixture(
        activity: ClassActivity? = nil, courseCode: String = "CS135", archived: Bool = false, on app: Application
    ) async throws -> Fixture {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "tile.py")], language: .python,
            activity: activity ?? ClassActivity(kind: .classComposite, composite: spec))
        let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
        let course = try await makeTestCourse(on: app, code: courseCode, archived: archived)
        let courseID = try course.requireID()
        let setupID = "setup_\(courseCode.lowercased())"
        try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: manifest)
        let assignment = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
        return Fixture(assignmentID: try assignment.requireID(), courseID: courseID, setupID: setupID)
    }

    /// An enrolled student with a dealt slot.
    private func student(_ name: String, _ f: Fixture, on app: Application) async throws -> UUID {
        let id = try await makeTestStudent(on: app, username: name).requireID()
        try await makeTestEnrollment(on: app, userID: id, courseID: f.courseID)
        _ = try await CompositeSlots.slot(assignmentID: f.assignmentID, userID: id, spec: spec, on: app.db)
        return id
    }

    private func submission(
        _ id: String, by userID: UUID, _ f: Fixture, at date: Date = Date(), on app: Application
    ) async throws -> APISubmission {
        let submission = try await makeTestSubmission(on: app, id: id, setupID: f.setupID, userID: userID)
        submission.submittedAt = date
        try await submission.save(on: app.db)
        return submission
    }

    private func collection(
        _ submissionID: String, setupID: String, status: TestStatus = .pass,
        composite: CompositeContribution?
    ) -> TestOutcomeCollection {
        let outcome = TestOutcome(
            testName: "tile.py", testClass: nil, tier: .pub, status: status, shortResult: "",
            longResult: nil, composite: composite, executionTimeMs: 1, memoryUsageBytes: nil,
            attemptNumber: 1, isFirstPassSuccess: status == .pass)
        return TestOutcomeCollection(
            submissionID: submissionID, testSetupID: setupID, attemptNumber: 1, buildStatus: .passed,
            compilerOutput: nil, outcomes: [outcome], totalTests: 1, passCount: status == .pass ? 1 : 0,
            failCount: status == .pass ? 0 : 1, errorCount: 0, timeoutCount: 0, executionTimeMs: 1,
            runnerVersion: "test", timestamp: Date())
    }

    private func contribution(_ data: String? = nil, width: Int = 2) -> CompositeContribution {
        CompositeContribution(width: width, height: 1, frames: 1, format: .gray8, data: data ?? twoBytes)
    }

    // MARK: - The payload check

    @Test func onlyTheAssignmentsShapeWithTheRightLengthIsValid() {
        #expect(CompositeContributions.isValid(contribution(), for: shape))
        #expect(!CompositeContributions.isValid(contribution(width: 1), for: shape), "another shape")
        let threeBytes = Data([1, 2, 3]).base64EncodedString()
        #expect(!CompositeContributions.isValid(contribution(threeBytes), for: shape), "a wrong length")
        #expect(!CompositeContributions.isValid(contribution("not base64!"), for: shape))
        #expect(!CompositeContributions.isValid(contribution("CsgA"), for: shape), "three bytes in four characters")
        #expect(!CompositeContributions.isValid(contribution("Csg"), for: shape), "unpadded")
        #expect(!CompositeContributions.isValid(contribution("Cs g="), for: shape), "whitespace")
    }

    // MARK: - Recording

    @Test func aPassingContributionIsStoredAndCoversItsSlot() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let id = try await student("cc_a", f, on: app)
            let sub = try await submission("sub_a", by: id, f, on: app)
            let outcome = try await CompositeContributions.record(
                submission: sub, collection: collection("sub_a", setupID: f.setupID, composite: contribution()),
                on: app.db)
            #expect(outcome == .stored(slot: 0, passed: true))
            let row = try #require(try await APICompositeContribution.query(on: app.db).first())
            #expect(row.slot == 0)
            #expect(row.data == twoBytes)
            #expect(row.format == "gray8")
            #expect(row.passed)
            let coverage = try await APIClassItemCoverage.query(on: app.db).all()
            #expect(coverage.map(\.item) == ["slot-0"])
            #expect(coverage.first?.submissionID == "sub_a")
        }
    }

    @Test func aFailedContributionIsStoredButCoversNothing() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let id = try await student("cc_b", f, on: app)
            let sub = try await submission("sub_b", by: id, f, on: app)
            let outcome = try await CompositeContributions.record(
                submission: sub,
                collection: collection("sub_b", setupID: f.setupID, status: .fail, composite: contribution()),
                on: app.db)
            #expect(outcome == .stored(slot: 0, passed: false))
            #expect(try await APICompositeContribution.query(on: app.db).count() == 1)
            #expect(try await APIClassItemCoverage.query(on: app.db).count() == 0)
        }
    }

    @Test func anInvalidPayloadIsDiscarded() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let id = try await student("cc_c", f, on: app)
            let sub = try await submission("sub_c", by: id, f, on: app)
            let outcome = try await CompositeContributions.record(
                submission: sub,
                collection: collection("sub_c", setupID: f.setupID, composite: contribution(width: 1)),
                on: app.db)
            #expect(outcome == .discarded)
            #expect(try await APICompositeContribution.query(on: app.db).count() == 0)
            #expect(try await APIClassItemCoverage.query(on: app.db).count() == 0)
        }
    }

    /// The newer submission replaces the row. An older one, re-tested later,
    /// does not. The first passing contribution keeps the coverage row.
    @Test func theNewestSubmissionWins() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let id = try await student("cc_d", f, on: app)
            let now = Date()
            let old = try await submission("sub_old", by: id, f, at: now.addingTimeInterval(-60), on: app)
            let new = try await submission("sub_new", by: id, f, at: now, on: app)
            let other = Data([0, 0]).base64EncodedString()

            try await CompositeContributions.record(
                submission: old, collection: collection("sub_old", setupID: f.setupID, composite: contribution()),
                on: app.db)
            let replaced = try await CompositeContributions.record(
                submission: new,
                collection: collection("sub_new", setupID: f.setupID, status: .fail, composite: contribution(other)),
                on: app.db)
            #expect(replaced == .stored(slot: 0, passed: false))
            let retested = try await CompositeContributions.record(
                submission: old, collection: collection("sub_old", setupID: f.setupID, composite: contribution()),
                on: app.db)
            #expect(retested == .superseded)

            let rows = try await APICompositeContribution.query(on: app.db).all()
            #expect(rows.count == 1)
            #expect(rows.first?.submissionID == "sub_new")
            #expect(rows.first?.data == other)
            #expect(try await APIClassItemCoverage.query(on: app.db).all().map(\.submissionID) == ["sub_old"])
        }
    }

    /// Two results for one student at once: the newer submission is the one
    /// left stored, in either order.
    @Test func concurrentResultsLeaveTheNewerSubmission() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let id = try await student("cc_race", f, on: app)
            let now = Date()
            let old = try await submission("sub_race_old", by: id, f, at: now.addingTimeInterval(-60), on: app)
            let new = try await submission("sub_race_new", by: id, f, at: now, on: app)
            let setupID = f.setupID
            let first = contribution()
            // Rounds after the first exercise the update, not the insert.
            for _ in 0..<5 {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for (sub, subID) in [(old, "sub_race_old"), (new, "sub_race_new")] {
                        group.addTask {
                            try await CompositeContributions.record(
                                submission: sub, collection: collection(subID, setupID: setupID, composite: first),
                                on: app.db)
                        }
                    }
                    try await group.waitForAll()
                }
                let rows = try await APICompositeContribution.query(on: app.db).all()
                #expect(rows.map(\.submissionID) == ["sub_race_new"])
            }
        }
    }

    @Test func aStaffSubmissionOrAnotherKindRecordsNothing() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let staff = try await makeTestUser(on: app, username: "cc_staff", role: "instructor").requireID()
            try await makeTestEnrollment(on: app, userID: staff, courseID: f.courseID)
            let staffSub = try await submission("sub_staff", by: staff, f, on: app)
            #expect(
                try await CompositeContributions.record(
                    submission: staffSub,
                    collection: collection("sub_staff", setupID: f.setupID, composite: contribution()),
                    on: app.db) == .notApplicable)

            let metric = try await fixture(activity: ClassActivity(kind: .bestMetric), courseCode: "CS136", on: app)
            let id = try await makeTestStudent(on: app, username: "cc_metric").requireID()
            try await makeTestEnrollment(on: app, userID: id, courseID: metric.courseID)
            let sub = try await submission("sub_metric", by: id, metric, on: app)
            #expect(
                try await CompositeContributions.record(
                    submission: sub,
                    collection: collection("sub_metric", setupID: metric.setupID, composite: contribution()),
                    on: app.db) == .notApplicable)
            #expect(try await APICompositeContribution.query(on: app.db).count() == 0)
        }
    }

    @Test func aStudentWithNoSlotRecordsNothing() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let id = try await makeTestStudent(on: app, username: "cc_noslot").requireID()
            try await makeTestEnrollment(on: app, userID: id, courseID: f.courseID)
            let sub = try await submission("sub_noslot", by: id, f, on: app)
            #expect(
                try await CompositeContributions.record(
                    submission: sub,
                    collection: collection("sub_noslot", setupID: f.setupID, composite: contribution()),
                    on: app.db) == .noSlot)
        }
    }

    /// Both result paths call `ResultIngestEffects.apply`, so this is the
    /// wiring for each of them.
    @Test func theSharedIngestEffectsRecordTheContribution() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let id = try await student("cc_e", f, on: app)
            let sub = try await submission("sub_e", by: id, f, on: app)
            await ResultIngestEffects(application: app, db: app.db, logger: app.logger).apply(
                submission: sub, collection: collection("sub_e", setupID: f.setupID, composite: contribution()))
            #expect(try await APICompositeContribution.query(on: app.db).count() == 1)
            #expect(try await APIClassItemCoverage.query(on: app.db).all().map(\.item) == ["slot-0"])
        }
    }

    // MARK: - Course deletion

    @Test func deletingACourseRemovesItsSlotsAndContributions() async throws {
        let app = try await makeTestApp(prefix: "chickadee-delete-composite")
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("delete_composite_admin", on: app)
            let f = try await fixture(archived: true, on: app)
            let course = try #require(try await APICourse.find(f.courseID, on: app.db))
            // Past the 365-day retention window, so deletion is permitted.
            course.archivedAt = Date().addingTimeInterval(-400 * 86_400)
            try await course.save(on: app.db)
            let id = try await student("cc_f", f, on: app)
            let sub = try await submission("sub_f", by: id, f, on: app)
            try await CompositeContributions.record(
                submission: sub, collection: collection("sub_f", setupID: f.setupID, composite: contribution()),
                on: app.db)

            let path = "/admin/courses/\(f.courseID.uuidString)"
            let (token, boundCookie) = try await csrfFields(for: path, cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "\(path)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            #expect(try await APICourse.find(f.courseID, on: app.db) == nil)
            #expect(try await APICompositeSlot.query(on: app.db).count() == 0)
            #expect(try await APICompositeContribution.query(on: app.db).count() == 0)
            #expect(try await APIClassItemCoverage.query(on: app.db).count() == 0)
        }
    }
}
