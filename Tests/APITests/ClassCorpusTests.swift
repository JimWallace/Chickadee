// Tests/APITests/ClassCorpusTests.swift
//
// The synthetic class corpus run (docs/collaborative-class-assignments.md,
// Phase 4): the class's contributed slot cells assembled into one notebook,
// graded once, and the coverage number that grade produces.
//
// The rules pinned here are the ones `ClassCorpus.swift` documents — the corpus
// is roster-scoped and slot-bounded, deterministic under the same inputs, owned
// by no student, opt-in behind a `classCoverage` goal, debounced to one run in
// flight, and read back as the latest COMPLETED run.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct ClassCorpusTests {

    // MARK: - Fixtures

    private func notebookJSON(cells: [String]) -> String {
        let body = cells.joined(separator: ",")
        return """
            {"cells":[\(body)],"metadata":{"kernelspec":{"name":"xpython"}},\
            "nbformat":4,"nbformat_minor":5}
            """
    }

    private func slotCell(_ source: String, slot: String) -> String {
        """
        {"cell_type":"code","metadata":{"chickadee_slot":"\(slot)"},\
        "source":"\(source)","outputs":[],"execution_count":null}
        """
    }

    private func plainCell(_ source: String) -> String {
        """
        {"cell_type":"code","metadata":{},"source":"\(source)",\
        "outputs":[],"execution_count":null}
        """
    }

    private func testCell(_ source: String) -> String {
        plainCell("# TEST: tier=public\\n\(source)")
    }

    /// A manifest declaring a class goal the corpus run answers, unless
    /// `withCoverageGoal` is false (then the assignment asks for no number and
    /// no run should be enqueued).
    private func manifest(withCoverageGoal: Bool) throws -> String {
        let goals: [Achievement] =
            withCoverageGoal
            ? [
                Achievement(
                    id: "cov", name: "Class coverage", scope: .classWide,
                    conditions: [
                        AchievementCondition(signal: .classCoverage, comparator: .atLeast, value: 80)
                    ],
                    reward: AchievementReward(type: .points, label: "Coverage", points: 2),
                    classFraction: 0.5)
            ] : []
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "test_corpus.sh")],
            achievements: goals)
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    private struct Fixture {
        let setup: APITestSetup
        let a: APIUser
        let b: APIUser
        var setupID: String { setup.id ?? "" }
    }

    /// One contribution assignment with a two-slot starter notebook and two
    /// enrolled students, neither of whom has submitted yet.
    private func fixture(
        _ app: Application, prefix: String, withCoverageGoal: Bool = true,
        declaresSlots: Bool = true
    ) async throws -> Fixture {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let setupID = "\(prefix)_setup"
        let starter =
            declaresSlots
            ? notebookJSON(cells: [
                slotCell("# write your first test here", slot: "1"),
                slotCell("# write your second test here", slot: "2"),
                testCell("assert well_formed()"),
            ])
            : notebookJSON(cells: [plainCell("scaffold"), testCell("assert well_formed()")])
        let notebookPath = app.testSetupsDirectory + "\(setupID).ipynb"
        try Data(starter.utf8).write(to: URL(fileURLWithPath: notebookPath))
        let setup = APITestSetup(
            id: setupID, manifest: try manifest(withCoverageGoal: withCoverageGoal),
            zipPath: app.testSetupsDirectory + "\(setupID).zip",
            notebookPath: notebookPath, courseID: courseID)
        try await setup.save(on: app.db)
        _ = try await arInsertAssignment(
            testSetupID: setupID, title: "Bug hunt \(prefix)", isOpen: true, on: app)

        var users: [APIUser] = []
        for name in ["a", "b"] {
            let user = try await arInsertStudent(username: "\(prefix)_\(name)", on: app)
            try await arEnrollStudentInTestCourse(user, on: app)
            users.append(user)
        }
        return Fixture(setup: setup, a: users[0], b: users[1])
    }

    /// Stores one submission the way the submit path does: the merged notebook
    /// on disk, an `.ipynb` filename, complete.
    @discardableResult
    private func submit(
        _ app: Application, fx: Fixture, user: APIUser, id: String,
        slots: [String], kind: String = APISubmission.Kind.student
    ) async throws -> APISubmission {
        let cells =
            slots.enumerated().map { slotCell($0.element, slot: "\($0.offset + 1)") }
            + [testCell("assert well_formed()")]
        let path = app.submissionsDirectory + "\(id).ipynb"
        try Data(notebookJSON(cells: cells).utf8).write(to: URL(fileURLWithPath: path))
        let submission = APISubmission(
            id: id, testSetupID: fx.setupID, zipPath: path, attemptNumber: 1,
            status: "complete", filename: "lab.ipynb", userID: try user.requireID(), kind: kind)
        try await submission.save(on: app.db)
        return submission
    }

    private func collection(_ submissionID: String, earned: Double, total: Int) -> TestOutcomeCollection {
        TestOutcomeCollection(
            submissionID: submissionID, testSetupID: "", attemptNumber: 1,
            buildStatus: .passed, compilerOutput: nil, outcomes: [],
            totalTests: total, passCount: 0, failCount: 0, errorCount: 0, timeoutCount: 0,
            executionTimeMs: 1, totalPoints: total, earnedPoints: earned,
            runnerVersion: "test", timestamp: Date())
    }

    // MARK: - Assembling the corpus

    /// Every contributor's slot cells, in one notebook, with the instructor's
    /// test cells behind them — and the same inputs always give the same bytes.
    @Test func theCorpusHoldsEveryContributionAndIsDeterministic() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "build")
            try await submit(app, fx: fx, user: fx.a, id: "build_a1", slots: ["test_a1", "test_a2"])
            try await submit(app, fx: fx, user: fx.b, id: "build_b1", slots: ["test_b1"])

            let corpus = try #require(
                try await assembleClassCorpus(setup: fx.setup, app: app, on: app.db))
            #expect(corpus.contributors.count == 2)
            let cells = try #require(NotebookCellSources.cells(from: corpus.notebook))
            let sources = cells.map(NotebookCellSources.cellSource)
            #expect(sources.contains("test_a1"))
            #expect(sources.contains("test_a2"))
            #expect(sources.contains("test_b1"))
            // The instructor's test cell rides behind the contributions, and
            // the starter's own empty prompts are not contributions.
            #expect(sources.filter { $0.hasPrefix("# TEST:") }.count == 1)
            #expect(!sources.contains { $0.contains("write your first test") })

            let again = try #require(
                try await assembleClassCorpus(setup: fx.setup, app: app, on: app.db))
            #expect(again.notebook == corpus.notebook)
        }
    }

    /// A submission with nothing in any slot contributes no cell and no
    /// contributor, so it cannot inflate the breadth half of a goal.
    @Test func anEmptySubmissionIsNotAContribution() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "empty")
            try await submit(app, fx: fx, user: fx.a, id: "empty_a1", slots: ["test_a1"])
            try await submit(app, fx: fx, user: fx.b, id: "empty_b1", slots: ["   "])

            let corpus = try #require(
                try await assembleClassCorpus(setup: fx.setup, app: app, on: app.db))
            #expect(corpus.contributors == [try fx.a.requireID()])
        }
    }

    /// Staff never enter the corpus: an instructor's own test submission would
    /// report the reference solution's coverage as the class's.
    @Test func staffContributionsStayOutOfTheCorpus() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "staff")
            let ta = try await arInsertStudent(username: "staff_ta", on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            try await APICourseEnrollment(userID: try ta.requireID(), courseID: courseID, role: .ta)
                .save(on: app.db)
            try await submit(app, fx: fx, user: ta, id: "staff_ta1", slots: ["reference_suite"])
            try await submit(app, fx: fx, user: fx.a, id: "staff_a1", slots: ["test_a1"])

            let corpus = try #require(
                try await assembleClassCorpus(setup: fx.setup, app: app, on: app.db))
            #expect(corpus.contributors == [try fx.a.requireID()])
            let sources = try #require(NotebookCellSources.cells(from: corpus.notebook))
                .map(NotebookCellSources.cellSource)
            #expect(!sources.contains("reference_suite"))
        }
    }

    /// An assignment that declares no contribution slots has no corpus, which
    /// is what keeps every ordinary assignment off this path.
    @Test func anOrdinaryAssignmentHasNoCorpus() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "plain", declaresSlots: false)
            try await submit(app, fx: fx, user: fx.a, id: "plain_a1", slots: ["test_a1"])

            #expect(try await assembleClassCorpus(setup: fx.setup, app: app, on: app.db) == nil)
        }
    }

    // MARK: - Enqueueing the run

    /// The corpus submission belongs to nobody, carries the aggregate kind, and
    /// opens exactly one run row.
    @Test func theCorpusRunIsOwnedByNoStudent() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "own")
            try await submit(app, fx: fx, user: fx.a, id: "own_a1", slots: ["test_a1"])
            await scheduleClassCorpusRun(
                setupID: fx.setupID, app: app, on: app.db, logger: app.logger)

            let aggregates = try await APISubmission.query(on: app.db)
                .filter(\.$kind == APISubmission.Kind.classAggregate).all()
            #expect(aggregates.count == 1)
            #expect(aggregates.first?.userID == nil)
            #expect(aggregates.first?.status == SubmissionStatus.pending.rawValue)

            let runs = try await APIClassCoverageRun.query(on: app.db).all()
            #expect(runs.count == 1)
            #expect(runs.first?.coverage == nil)
            #expect(runs.first?.contributors == [try fx.a.requireID()])
        }
    }

    /// One run in flight at a time: a deadline spike queues one corpus run, not
    /// one per submission.
    @Test func aSecondScheduleWhileOneIsInFlightIsANoOp() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "debounce")
            try await submit(app, fx: fx, user: fx.a, id: "debounce_a1", slots: ["test_a1"])
            await scheduleClassCorpusRun(
                setupID: fx.setupID, app: app, on: app.db, logger: app.logger)
            try await submit(app, fx: fx, user: fx.b, id: "debounce_b1", slots: ["test_b1"])
            await scheduleClassCorpusRun(
                setupID: fx.setupID, app: app, on: app.db, logger: app.logger)

            #expect(try await APIClassCoverageRun.query(on: app.db).count() == 1)

            // Once the run lands, the next contribution starts the next one.
            let run = try #require(try await APIClassCoverageRun.query(on: app.db).first())
            let submission = try #require(
                try await APISubmission.find(run.submissionID, on: app.db))
            try await recordClassCoverageRun(
                submission: submission, collection: collection(run.submissionID, earned: 4, total: 5),
                on: app.db)
            await scheduleClassCorpusRun(
                setupID: fx.setupID, app: app, on: app.db, logger: app.logger)
            #expect(try await APIClassCoverageRun.query(on: app.db).count() == 2)
        }
    }

    /// An assignment with no `classCoverage` goal asks for no number, so it
    /// spends no runner time producing one.
    @Test func noGoalMeansNoRun() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "nogoal", withCoverageGoal: false)
            try await submit(app, fx: fx, user: fx.a, id: "nogoal_a1", slots: ["test_a1"])
            await scheduleClassCorpusRun(
                setupID: fx.setupID, app: app, on: app.db, logger: app.logger)

            #expect(try await APIClassCoverageRun.query(on: app.db).count() == 0)
            #expect(
                try await APISubmission.query(on: app.db)
                    .filter(\.$kind == APISubmission.Kind.classAggregate).count() == 0)
        }
    }

    // MARK: - Reading the result back

    /// The run's grade fraction is the coverage number, and the latest
    /// COMPLETED run is what a reader gets.
    @Test func theLatestCompletedRunCarriesTheNumber() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "read")
            try await submit(app, fx: fx, user: fx.a, id: "read_a1", slots: ["test_a1"])
            await scheduleClassCorpusRun(
                setupID: fx.setupID, app: app, on: app.db, logger: app.logger)
            let first = try #require(try await APIClassCoverageRun.query(on: app.db).first())
            let firstSubmission = try #require(
                try await APISubmission.find(first.submissionID, on: app.db))
            try await recordClassCoverageRun(
                submission: firstSubmission,
                collection: collection(first.submissionID, earned: 3, total: 4), on: app.db)

            let landed = try #require(
                try await latestClassCoverageRun(testSetupID: fx.setupID, on: app.db))
            #expect(landed.coverage == 0.75)
            #expect(landed.completedAt != nil)

            // A queued next run does not replace the number a reader sees.
            try await submit(app, fx: fx, user: fx.b, id: "read_b1", slots: ["test_b1"])
            await scheduleClassCorpusRun(
                setupID: fx.setupID, app: app, on: app.db, logger: app.logger)
            let stillLanded = try #require(
                try await latestClassCoverageRun(testSetupID: fx.setupID, on: app.db))
            #expect(stillLanded.coverage == 0.75)
        }
    }

    /// A corpus that could not build says nothing about what the class covers,
    /// so the run completes with no number rather than with zero.
    @Test func aFailedBuildCompletesTheRunWithoutANumber() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "failed")
            try await submit(app, fx: fx, user: fx.a, id: "failed_a1", slots: ["test_a1"])
            await scheduleClassCorpusRun(
                setupID: fx.setupID, app: app, on: app.db, logger: app.logger)
            let run = try #require(try await APIClassCoverageRun.query(on: app.db).first())
            let submission = try #require(
                try await APISubmission.find(run.submissionID, on: app.db))
            var failed = collection(run.submissionID, earned: 0, total: 4)
            failed = TestOutcomeCollection(
                submissionID: failed.submissionID, testSetupID: "", attemptNumber: 1,
                buildStatus: .failed, compilerOutput: "NameError", outcomes: [],
                totalTests: 0, passCount: 0, failCount: 0, errorCount: 0, timeoutCount: 0,
                executionTimeMs: 1, totalPoints: 4, earnedPoints: 0,
                runnerVersion: "test", timestamp: Date())
            try await recordClassCoverageRun(
                submission: submission, collection: failed, on: app.db)

            let reloaded = try #require(
                try await APIClassCoverageRun.find(run.id, on: app.db))
            #expect(reloaded.coverage == nil)
            #expect(reloaded.completedAt != nil, "the run completed, so the debounce releases")
            #expect(try await latestClassCoverageRun(testSetupID: fx.setupID, on: app.db) == nil)
        }
    }
}
