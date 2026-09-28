// The CLASS CORPUS goal: a collaborative assignment graded on how much of the
// reference the class's COMBINED contributions cover, rather than on a union of
// per-item rows or a count of students clearing a grade threshold.
//
// It is the third evaluable class-goal shape and the second two-halved one:
//
//   * COVERAGE — the corpus run's own grade, the share of the reference the
//     class's assembled contributions exercise;
//   * BREADTH — at least `classFraction` of the roster put a cell in it.
//
// Breadth is the anti-solo-hero half here for the same reason it is on a union
// goal: one student writing an exhaustive suite in their own slots reaches full
// coverage alone and then fails the goal on breadth.
//
// The asymmetry worth pinning is the one this shape adds: the sweep reads the
// LATEST COMPLETED run and nothing else, so a queued re-run cannot blank a
// number that freezes into a grade push.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct ClassCoverageGoalTests {

    // MARK: - Pure progress math (no DB)

    /// The bar reports the SMALLER half, as the union goal's does.
    @Test func corpusProgressIsTheSmallerOfCoverageAndBreadth() {
        // Coverage complete, breadth at half → half.
        #expect(
            classCoverageGoalProgress(
                coveragePercent: 90, requiredPercent: 80,
                studentsContributing: 3, denominator: 10, classFraction: 0.6) == 0.5)
        // Breadth complete, coverage at half → half.
        #expect(
            classCoverageGoalProgress(
                coveragePercent: 40, requiredPercent: 80,
                studentsContributing: 6, denominator: 10, classFraction: 0.6) == 0.5)
        // Both complete.
        #expect(
            classCoverageGoalProgress(
                coveragePercent: 80, requiredPercent: 80,
                studentsContributing: 6, denominator: 10, classFraction: 0.6) == 1.0)
    }

    /// The solo hero, stated as arithmetic: the whole reference covered, by one
    /// student, on a roster of ten with a 60% breadth requirement.
    @Test func oneStudentCoveringEverythingDoesNotMeetTheGoal() {
        let progress = classCoverageGoalProgress(
            coveragePercent: 100, requiredPercent: 80,
            studentsContributing: 1, denominator: 10, classFraction: 0.6)
        #expect(progress < 1.0)
        #expect(progress == (1.0 / 10.0) / 0.6)
    }

    @Test func corpusProgressClampsAndHandlesDegenerateInputs() {
        // Over-coverage clamps rather than exceeding the goal.
        #expect(
            classCoverageGoalProgress(
                coveragePercent: 100, requiredPercent: 40,
                studentsContributing: 10, denominator: 10, classFraction: 0.6) == 1.0)
        // Asking for no coverage leaves breadth as the whole goal.
        #expect(
            classCoverageGoalProgress(
                coveragePercent: 0, requiredPercent: 0,
                studentsContributing: 6, denominator: 10, classFraction: 0.6) == 1.0)
        // An empty roster is 0, matching `classGoalProgress` rather than
        // dividing by it.
        #expect(
            classCoverageGoalProgress(
                coveragePercent: 100, requiredPercent: 80,
                studentsContributing: 0, denominator: 0, classFraction: 0.6) == 0)
    }

    // MARK: - Which shapes the sweep will evaluate

    private func coverageGoal(
        value: Double = 80, target: AchievementTarget? = nil,
        comparator: ConditionComparator = .atLeast, scope: AchievementScope = .classWide
    ) -> Achievement {
        Achievement(
            id: "c", name: "Class coverage", scope: scope,
            conditions: [
                AchievementCondition(
                    signal: .classCoverage, comparator: comparator, value: value, target: target)
            ],
            reward: AchievementReward(type: .points, label: "Coverage", points: 5),
            classFraction: 0.6)
    }

    @Test func theSweepAcceptsAnUnscopedClassCoverageGoal() {
        let goal = coverageGoal()
        #expect(goal.isSweepEvaluableClassGoal)
        #expect(goal.isCoverageClassGoal)
        #expect(goal.coveragePercentRequirement == 80)
        #expect(!goal.isUnionClassGoal, "the three shapes are mutually exclusive")
    }

    /// The guard stays closed on everything else, as it is for the union shape
    /// (audit A4).
    @Test func theSweepRefusesUnreadableCoverageShapes() {
        // The corpus run produces ONE number for the assignment, so a target
        // would name a share of a reference nothing measured.
        for kind in [TargetKind.section, .assignmentGrade, .suiteItem, .testPass] {
            #expect(
                !coverageGoal(target: AchievementTarget(kind: kind, ref: "x"))
                    .isSweepEvaluableClassGoal,
                "a \(kind) target scopes nothing a corpus run measured")
        }
        // Coverage counts up, so only atLeast renders on a progress bar.
        #expect(!coverageGoal(comparator: .atMost).isSweepEvaluableClassGoal)
        #expect(!coverageGoal(comparator: .equals).isSweepEvaluableClassGoal)
    }

    /// Arity stays at one. Admitting a third shape must not relax the rule that
    /// made the guard worth having.
    @Test func theSweepStillRefusesMultipleConditions() {
        let goal = Achievement(
            id: "c2", name: "Both", scope: .classWide,
            conditions: [
                AchievementCondition(signal: .classCoverage, comparator: .atLeast, value: 80),
                AchievementCondition(signal: .grade, comparator: .atLeast, value: 50),
            ],
            reward: AchievementReward(type: .points, label: "Both", points: 5),
            classFraction: 0.6)
        #expect(!goal.isSweepEvaluableClassGoal)
    }

    /// `classCoverage` reads the class, not a submission, so no per-submission
    /// evaluation may claim it holds — the unknown-signal convention.
    @Test func classCoverageIsNeverSatisfiedByOneSubmissionsSignals() {
        let condition = AchievementCondition(
            signal: .classCoverage, comparator: .atLeast, value: 0)
        #expect(!condition.isSatisfied(by: AchievementSignals(gradePercent: 100)))
    }

    /// It is a whole-class signal, so authoring refuses it off `classWide`: an
    /// individual badge carrying it would save cleanly and never fire.
    @Test func classCoverageIsRefusedOffAClassGoal() {
        #expect(AchievementSignal.classCoverage.readsTheWholeClass)
        #expect(AchievementSignal.classCoverage.allowedScopes == [.classWide])
        #expect(!coverageGoal(scope: .individual).isSweepEvaluableClassGoal)
    }

    // MARK: - The full sweep (DB-backed)

    private func coverageManifest() throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "coverage.sh")],
            achievements: [
                Achievement(
                    id: "cov", name: "Class coverage", scope: .classWide,
                    conditions: [
                        AchievementCondition(signal: .classCoverage, comparator: .atLeast, value: 80)
                    ],
                    reward: AchievementReward(type: .points, label: "Coverage", points: 5),
                    classFraction: 0.5)
            ])
        return try #require(String(bytes: try JSONEncoder().encode(props), encoding: .utf8))
    }

    /// Records one completed corpus run directly. `ClassCorpusTests` owns the
    /// assembly and the enqueue; what is under test here is what the sweep
    /// makes of a run that has landed.
    @discardableResult
    private func landRun(
        setupID: String, coverage: Double, contributors: [UUID], at date: Date,
        on db: Database
    ) async throws -> APIClassCoverageRun {
        let run = APIClassCoverageRun(
            testSetupID: setupID, submissionID: "sub_\(UUID().uuidString.prefix(8))",
            contributors: contributors, createdAt: date)
        run.coverage = coverage
        run.completedAt = date
        try await run.save(on: db)
        return run
    }

    @Test func theSweepGradesACoverageGoalOnCoverageAndBreadth() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setup = APITestSetup(
                id: "cov_setup", manifest: try coverageManifest(),
                zipPath: app.testSetupsDirectory + "cov_setup.zip", courseID: courseID)
            try await setup.save(on: app.db)
            _ = try await arInsertAssignment(
                testSetupID: "cov_setup", title: "Coverage Lab", isOpen: true, on: app)

            let a = try await arInsertStudent(username: "cov_a", on: app)
            try await arEnrollStudentInTestCourse(a, on: app)
            let b = try await arInsertStudent(username: "cov_b", on: app)
            try await arEnrollStudentInTestCourse(b, on: app)

            try await landRun(
                setupID: "cov_setup", coverage: 0.6,
                contributors: [try a.requireID(), try b.requireID()], at: Date(), on: app.db)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)

            let snapshot = try #require(
                try await APIAchievementResult.query(on: app.db)
                    .filter(\.$testSetupID == "cov_setup").first())
            #expect(snapshot.coveragePercent == 60)
            #expect(snapshot.coverageRequired == 80)
            #expect(snapshot.itemsCovered == nil, "a corpus goal unions nothing")
            #expect(snapshot.studentsMeeting == 2, "both students contributed")
            #expect(snapshot.denominator == 2)
            #expect(snapshot.progress == 60.0 / 80.0, "coverage is the smaller half")
        }
    }

    /// "The goal reads the latest aggregate only": an earlier run's number is
    /// superseded outright rather than averaged or accumulated.
    @Test func theSweepReadsTheLatestCompletedRunOnly() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setup = APITestSetup(
                id: "late_setup", manifest: try coverageManifest(),
                zipPath: app.testSetupsDirectory + "late_setup.zip", courseID: courseID)
            try await setup.save(on: app.db)
            _ = try await arInsertAssignment(
                testSetupID: "late_setup", title: "Latest Lab", isOpen: true, on: app)

            let a = try await arInsertStudent(username: "late_a", on: app)
            try await arEnrollStudentInTestCourse(a, on: app)
            let b = try await arInsertStudent(username: "late_b", on: app)
            try await arEnrollStudentInTestCourse(b, on: app)
            let both = [try a.requireID(), try b.requireID()]

            let earlier = Date().addingTimeInterval(-600)
            try await landRun(
                setupID: "late_setup", coverage: 0.3, contributors: [try a.requireID()],
                at: earlier, on: app.db)
            try await landRun(
                setupID: "late_setup", coverage: 0.8, contributors: both, at: Date(), on: app.db)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)

            let snapshot = try #require(
                try await APIAchievementResult.query(on: app.db)
                    .filter(\.$testSetupID == "late_setup").first())
            #expect(snapshot.coveragePercent == 80)
            #expect(snapshot.studentsMeeting == 2)
            #expect(snapshot.progress == 1.0)
        }
    }

    /// BREADTH counts only currently-enrolled contributors (audit A7), while
    /// COVERAGE keeps what the corpus measured — the same split the union goal
    /// carries between the number and the roster.
    @Test func breadthCountsOnlyEnrolledContributors() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setup = APITestSetup(
                id: "drop_setup", manifest: try coverageManifest(),
                zipPath: app.testSetupsDirectory + "drop_setup.zip", courseID: courseID)
            try await setup.save(on: app.db)
            _ = try await arInsertAssignment(
                testSetupID: "drop_setup", title: "Drop Lab", isOpen: true, on: app)

            let a = try await arInsertStudent(username: "drop_a", on: app)
            try await arEnrollStudentInTestCourse(a, on: app)
            let b = try await arInsertStudent(username: "drop_b", on: app)
            try await arEnrollStudentInTestCourse(b, on: app)
            let gone = try await arInsertStudent(username: "drop_gone", on: app)

            // The corpus was assembled from three, one of whom has since left.
            try await landRun(
                setupID: "drop_setup", coverage: 1.0,
                contributors: [try a.requireID(), try b.requireID(), try gone.requireID()],
                at: Date(), on: app.db)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)

            let snapshot = try #require(
                try await APIAchievementResult.query(on: app.db)
                    .filter(\.$testSetupID == "drop_setup").first())
            #expect(snapshot.coveragePercent == 100, "the corpus covered what it covered")
            #expect(snapshot.studentsMeeting == 2, "the student who left is off the roster")
            #expect(snapshot.denominator == 2)
        }
    }

    /// No run yet reads as no coverage rather than as a met goal: an assignment
    /// nobody has contributed to has not covered the reference.
    @Test func noRunYetIsZeroCoverage() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setup = APITestSetup(
                id: "none_setup", manifest: try coverageManifest(),
                zipPath: app.testSetupsDirectory + "none_setup.zip", courseID: courseID)
            try await setup.save(on: app.db)
            _ = try await arInsertAssignment(
                testSetupID: "none_setup", title: "Empty Lab", isOpen: true, on: app)
            let a = try await arInsertStudent(username: "none_a", on: app)
            try await arEnrollStudentInTestCourse(a, on: app)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)

            let snapshot = try #require(
                try await APIAchievementResult.query(on: app.db)
                    .filter(\.$testSetupID == "none_setup").first())
            #expect(snapshot.coveragePercent == 0)
            #expect(snapshot.progress == 0)
        }
    }
}
