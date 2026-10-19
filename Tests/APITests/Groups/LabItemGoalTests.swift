// Tests/APITests/Groups/LabItemGoalTests.swift
//
// Item goals of an activity that runs once per lab group (docs/lab-groups.md,
// slice 5b): an item counts for the lab of the session it was submitted in,
// and for nobody without one; each lab's item goal is counted over its own
// coverage; a lab's composite tile and spare cover their slot in their lab,
// not in the class, and the holder's own tile takes the slot back from a
// spare; the first finder in a lab keeps an item; and course delete removes
// the lab coverage.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class LabItemGoalTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-lab-items")
    }

    private let setupID = "litem_setup"

    private struct Fixture {
        let setup: APITestSetup
        let assignment: APIAssignment
        let assignmentID: UUID
        let props: TestProperties
        let labA: UUID
        let labB: UUID
        /// The two item names, in suite order.
        let items: [String]
    }

    /// A course with Lab 101 and Lab 102 and a per-group assignment of
    /// `activity` with a goal that the lab covers both items.
    private func fixture(activity: ClassActivity) async throws -> Fixture {
        let course = try await makeTestCourse(on: app, code: "LIT1", mode: .closed)
        let courseID = try course.requireID()
        let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
        let labA = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db).requireID()
        let labB = try await CourseGroupStore.addGroup(named: "Lab 102", to: set, on: app.db).requireID()
        let props = TestProperties(
            testSuites: [
                TestSuiteEntry(tier: .pub, script: "bug_one.py"), TestSuiteEntry(tier: .pub, script: "bug_two.py"),
            ],
            language: .python,
            activity: activity,
            achievements: [
                Achievement(
                    id: "hunt", name: "Find the bugs", scope: .classWide,
                    conditions: [AchievementCondition(signal: .itemsCovered, comparator: .atLeast, value: 2)],
                    reward: AchievementReward(type: .points, label: "Bugs found", points: 2),
                    classFraction: 1)
            ])
        let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
        let setup = try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: manifest)
        let assignment = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
        let items = props.testSuites.map { runnerOutcomeTestName(displayName: $0.name, script: $0.script) }
        return Fixture(
            setup: setup, assignment: assignment, assignmentID: try assignment.requireID(), props: props,
            labA: labA, labB: labB, items: items)
    }

    /// An enrolled student who joins `group`'s session, or none.
    private func student(_ name: String, joining group: UUID?, _ f: Fixture) async throws -> UUID {
        let id = try await makeTestStudent(on: app, username: name).requireID()
        try await makeTestEnrollment(on: app, userID: id, courseID: f.setup.courseID)
        if let group {
            let session = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: group, by: nil, now: Date().addingTimeInterval(-60),
                on: app.db)
            let joinedAt = Date().addingTimeInterval(-30)
            try await ActivitySessionStore.join(
                code: ActivitySessionCode.code(secret: session.codeSecret, at: joinedAt), userID: id,
                now: joinedAt, on: app.db)
        }
        return id
    }

    /// A submission by `userID` that passes `items`.
    private func covers(_ items: [String], by userID: UUID) async throws {
        let id = "litem_\(UUID().uuidString.prefix(12))"
        _ = try await makeTestSubmission(on: app, id: id, setupID: setupID, userID: userID)
        let outcomes = items.map { item in
            TestOutcome(
                testName: item, testClass: nil, tier: .pub, status: .pass, shortResult: "", longResult: nil,
                executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: true)
        }
        try await recordClassItemCoverage(
            testSetupID: setupID, userID: userID, submissionID: id, outcomes: outcomes, declaredSlotCount: 2,
            on: app.db)
    }

    private func labItems(_ group: UUID) async throws -> [String] {
        try await APIGroupClassItemCoverage.query(on: app.db)
            .filter(\.$testSetupID == setupID).filter(\.$groupID == group).sort(\.$item).all().map(\.item)
    }

    @Test func anItemCountsForTheLabOfTheSessionItWasSubmittedIn() async throws {
        try await withApp(app) { _ in
            let f = try await fixture(activity: ClassActivity(kind: .bestMetric, runsPerGroup: true))
            let ada = try await student("litem_ada", joining: f.labA, f)
            let alan = try await student("litem_alan", joining: f.labB, f)
            let grace = try await student("litem_grace", joining: nil, f)
            try await covers([f.items[0]], by: ada)
            try await covers(f.items, by: alan)
            try await covers(f.items, by: grace)

            #expect(try await labItems(f.labA) == [f.items[0]])
            #expect(try await labItems(f.labB) == f.items.sorted(), "each lab covers the same items")
            #expect(try await APIClassItemCoverage.query(on: app.db).count() == 0, "no whole-class coverage")
            #expect(
                try await APIGroupClassItemCoverage.query(on: app.db).filter(\.$userID == grace).count() == 0,
                "a student with no session covers nothing")
        }
    }

    @Test func eachLabsItemGoalCountsItsOwnCoverage() async throws {
        try await withApp(app) { _ in
            let f = try await fixture(activity: ClassActivity(kind: .bestMetric, runsPerGroup: true))
            let ada = try await student("litem_ada", joining: f.labA, f)
            let alan = try await student("litem_alan", joining: f.labB, f)
            try await covers([f.items[0]], by: ada)
            try await covers(f.items, by: alan)
            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)

            func row(_ group: UUID) async throws -> APIGroupAchievementResult {
                try #require(
                    try await APIGroupAchievementResult.query(on: app.db)
                        .filter(\.$testSetupID == setupID).filter(\.$groupID == group).first())
            }
            let labA = try await row(f.labA)
            #expect(labA.itemsCovered == 1)
            #expect(labA.progress == 0.5)
            let labB = try await row(f.labB)
            #expect(labB.itemsCovered == 2)
            #expect(labB.progress == 1)
            #expect(try await APIAchievementResult.query(on: app.db).count() == 0)
            #expect(
                try await classGoalBonusPoints(testSetupID: setupID, props: f.props, userID: alan, on: app.db) == 2)
        }
    }

    @Test func aLabsTileAndSpareCoverTheirSlotInTheLab() async throws {
        try await withApp(app) { _ in
            let spec = CompositeSpec(
                compositor: .tile, layout: .grid(columns: 2, rows: 1),
                contribution: CompositeContributionShape(width: 2, height: 1, frames: 1, format: .gray8),
                dealOrder: .rowMajor)
            let f = try await fixture(
                activity: ClassActivity(kind: .classComposite, composite: spec, runsPerGroup: true))
            let ada = try await student("litem_ada", joining: f.labA, f)
            await CompositeSlots.dealOnOpen(setup: f.setup, assignment: f.assignment, userID: ada, on: app.db)
            let ben = try await student("litem_ben", joining: f.labA, f)
            await CompositeSlots.dealOnOpen(setup: f.setup, assignment: f.assignment, userID: ben, on: app.db)

            let pixels = Data([1, 2]).base64EncodedString()
            let outcome = TestOutcome(
                testName: "tile.py", testClass: nil, tier: .pub, status: .pass, shortResult: "", longResult: nil,
                composite: CompositeContribution(width: 2, height: 1, frames: 1, format: .gray8, data: pixels),
                executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: true)
            func collection(_ submissionID: String) -> TestOutcomeCollection {
                TestOutcomeCollection(
                    submissionID: submissionID, testSetupID: setupID, attemptNumber: 1, buildStatus: .passed,
                    compilerOutput: nil, outcomes: [outcome], totalTests: 1, passCount: 1, failCount: 0,
                    errorCount: 0, timeoutCount: 0, executionTimeMs: 1, runnerVersion: "test", timestamp: Date())
            }
            let own = try await makeTestSubmission(on: app, id: "litem_tile", setupID: setupID, userID: ada)
            try await CompositeContributions.record(submission: own, collection: collection("litem_tile"), on: app.db)

            // ada's spare fills slot 1 of Lab 101's image, which ben holds.
            let job = APISubmission(
                id: "litem_spare", testSetupID: setupID, zipPath: "unused", attemptNumber: 1, filename: nil,
                userID: nil, kind: APISubmission.Kind.compositeSpare)
            try await job.save(on: app.db)
            try await APIGroupCompositeSpare(
                assignmentID: f.assignmentID, groupID: f.labA, userID: ada, slot: 1, submissionID: "litem_spare"
            ).create(on: app.db)
            try await CompositeSpares.record(submission: job, collection: collection("litem_spare"), on: app.db)

            #expect(try await labItems(f.labA) == spec.coverageItems.sorted())
            #expect(try await APIClassItemCoverage.query(on: app.db).count() == 0, "no whole-class coverage")

            // ben's own tile takes slot 1 back from the spare.
            let bens = try await makeTestSubmission(on: app, id: "litem_ben_tile", setupID: setupID, userID: ben)
            try await CompositeContributions.record(
                submission: bens, collection: collection("litem_ben_tile"), on: app.db)
            let slotOne = try #require(
                try await APIGroupClassItemCoverage.query(on: app.db)
                    .filter(\.$groupID == f.labA).filter(\.$item == spec.coverageItems[1]).first())
            #expect(slotOne.userID == ben)
            #expect(slotOne.submissionID == "litem_ben_tile")
        }
    }

    @Test func theFirstFinderInALabKeepsTheItem() async throws {
        try await withApp(app) { _ in
            let f = try await fixture(activity: ClassActivity(kind: .bestMetric, runsPerGroup: true))
            let ada = try await student("litem_ada", joining: f.labA, f)
            let ben = try await student("litem_ben", joining: f.labA, f)
            try await recordLabItemCoverage(
                testSetupID: setupID, groupID: f.labA, items: [f.items[0]], userID: ada, submissionID: "first",
                on: app.db)
            try await recordLabItemCoverage(
                testSetupID: setupID, groupID: f.labA, items: [f.items[0]], userID: ben, submissionID: "second",
                on: app.db)
            let rows = try await APIGroupClassItemCoverage.query(on: app.db).all()
            #expect(rows.map(\.submissionID) == ["first"])
            #expect(rows.map(\.userID) == [ada])
        }
    }

    @Test func deletingTheCourseRemovesTheLabCoverage() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("litem_admin", on: app)
            let f = try await fixture(activity: ClassActivity(kind: .bestMetric, runsPerGroup: true))
            let ada = try await student("litem_ada", joining: f.labA, f)
            try await covers(f.items, by: ada)
            #expect(try await APIGroupClassItemCoverage.query(on: app.db).count() == 2)

            let course = try #require(try await APICourse.find(f.setup.courseID, on: app.db))
            course.isArchived = true
            // Past the 365-day retention window, so deletion is permitted.
            course.archivedAt = Date().addingTimeInterval(-400 * 86_400)
            try await course.save(on: app.db)
            let path = "/admin/courses/\(f.setup.courseID.uuidString)"
            let (token, boundCookie) = try await csrfFields(for: path, cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "\(path)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })
            #expect(try await APIGroupClassItemCoverage.query(on: app.db).count() == 0)
        }
    }
}
