// The UNION class goal: a collaborative assignment graded on what the class
// collectively covered, rather than on a count of students clearing a grade
// threshold.
//
// A union goal has two halves and is only met when both are:
//
//   * COVERAGE — the class has covered N distinct suite items between them;
//   * BREADTH — at least `classFraction` of the roster contributed at least one
//     covered item.
//
// Breadth is the anti-solo-hero half, and it is why this feature needs no
// per-item attribution cap: one student finding everything reaches full
// coverage and then fails the goal on breadth. A ranking rule ("credit the K
// rarest items to each student") would bound the solo hero too, and would break
// the sweep's determinism doing it — a later submission could change which of
// an earlier student's items counted. So the properties asserted here are the
// ones that make the cheaper lever sufficient.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct ClassUnionGoalTests {

    // MARK: - Pure progress math (no DB)

    /// The bar reports the SMALLER half, so a class that has met one and not
    /// the other cannot read as nearly done.
    @Test func unionProgressIsTheSmallerOfCoverageAndBreadth() {
        // Coverage complete, breadth at half → half.
        #expect(
            classUnionGoalProgress(
                itemsCovered: 15, itemsRequired: 15,
                studentsContributing: 3, denominator: 10, classFraction: 0.6) == 0.5)
        // Breadth complete, coverage at a third → a third.
        #expect(
            classUnionGoalProgress(
                itemsCovered: 5, itemsRequired: 15,
                studentsContributing: 6, denominator: 10, classFraction: 0.6) == 5.0 / 15.0)
        // Both complete.
        #expect(
            classUnionGoalProgress(
                itemsCovered: 15, itemsRequired: 15,
                studentsContributing: 6, denominator: 10, classFraction: 0.6) == 1.0)
    }

    /// The solo hero, stated as arithmetic: every item found, by one student,
    /// on a roster of ten with a 60% breadth requirement.
    @Test func oneStudentFindingEverythingDoesNotMeetTheGoal() {
        let progress = classUnionGoalProgress(
            itemsCovered: 15, itemsRequired: 15,
            studentsContributing: 1, denominator: 10, classFraction: 0.6)
        #expect(progress < 1.0)
        #expect(progress == (1.0 / 10.0) / 0.6)
    }

    @Test func unionProgressClampsAndHandlesDegenerateInputs() {
        // Over-coverage clamps rather than exceeding the goal.
        #expect(
            classUnionGoalProgress(
                itemsCovered: 40, itemsRequired: 15,
                studentsContributing: 10, denominator: 10, classFraction: 0.6) == 1.0)
        // Asking for no items leaves breadth as the whole goal.
        #expect(
            classUnionGoalProgress(
                itemsCovered: 0, itemsRequired: 0,
                studentsContributing: 6, denominator: 10, classFraction: 0.6) == 1.0)
        // An empty roster is 0, matching `classGoalProgress` rather than
        // dividing by it.
        #expect(
            classUnionGoalProgress(
                itemsCovered: 15, itemsRequired: 15,
                studentsContributing: 0, denominator: 0, classFraction: 0.6) == 0)
    }

    /// Monotonicity, the property the freeze depends on: more coverage and more
    /// contributors never lower the number.
    @Test func unionProgressIsMonotoneInBothHalves() {
        var previous = -1.0
        for step in 0...15 {
            let progress = classUnionGoalProgress(
                itemsCovered: step, itemsRequired: 15,
                studentsContributing: step, denominator: 15, classFraction: 1)
            #expect(progress >= previous)
            previous = progress
        }
    }

    // MARK: - Which items the union is taken over

    private func suite() -> TestProperties {
        TestProperties(
            testSuites: [
                TestSuiteEntry(tier: .secret, script: "variant_01.py", sectionID: "bugs"),
                TestSuiteEntry(tier: .secret, script: "variant_02.py", sectionID: "bugs"),
                TestSuiteEntry(
                    tier: .pub, script: "wellformed.py", name: "Your test runs",
                    sectionID: "gate"),
            ],
            sections: [
                TestSuiteSection(id: "bugs", name: "Seeded bugs"),
                TestSuiteSection(id: "gate", name: "Well-formedness"),
            ])
    }

    /// The reason section scoping exists: a bug hunt's suite carries a
    /// "your test is well-formed" gate beside the variants, and counting it
    /// inflates the union by one item nobody had to find.
    @Test func aSectionScopeCountsOnlyThatSectionsItems() {
        let scoped = suite().coveredItemNames(
            inScopeOf: AchievementTarget(kind: .section, ref: "bugs"))
        #expect(scoped == ["variant_01", "variant_02"])
    }

    @Test func noScopeCountsEveryItemInTheSuite() {
        #expect(
            suite().coveredItemNames(inScopeOf: nil)
                == ["variant_01", "variant_02", "Your test runs"])
    }

    /// Names are the runner-stamped form — display name, else filename stem —
    /// because that is what `recordClassItemCoverage` writes. A mismatch here
    /// would leave every intersection empty and the goal at 0% forever.
    @Test func itemNamesMatchTheFormCoverageRowsAreStoredIn() {
        let names = suite().coveredItemNames(inScopeOf: nil)
        #expect(names.contains("Your test runs"))
        #expect(!names.contains("wellformed.py"), "a stored row never carries the filename")
    }

    // MARK: - Which shapes the sweep will evaluate

    private func unionGoal(
        value: Double = 12, target: AchievementTarget? = nil,
        comparator: ConditionComparator = .atLeast
    ) -> Achievement {
        Achievement(
            id: "u", name: "Bug hunt", scope: .classWide,
            conditions: [
                AchievementCondition(
                    signal: .itemsCovered, comparator: comparator, value: value, target: target)
            ],
            reward: AchievementReward(type: .points, label: "Bug hunt", points: 5),
            classFraction: 0.6)
    }

    @Test func theSweepAcceptsAnItemsCoveredGoalWithOrWithoutASection() {
        #expect(unionGoal().isSweepEvaluableClassGoal)
        #expect(
            unionGoal(target: AchievementTarget(kind: .section, ref: "bugs"))
                .isSweepEvaluableClassGoal)
    }

    /// The guard stays closed on everything else. Each of these would otherwise
    /// be silently mis-evaluated rather than skipped (audit A4).
    @Test func theSweepRefusesUnreadableUnionShapes() {
        // A section scope naming nothing scopes the union to an empty item set.
        #expect(
            !unionGoal(target: AchievementTarget(kind: .section, ref: nil))
                .isSweepEvaluableClassGoal)
        // Targets that are not a set of items at all.
        for kind in [TargetKind.assignmentGrade, .suiteItem, .testPass] {
            #expect(
                !unionGoal(target: AchievementTarget(kind: kind, ref: "x"))
                    .isSweepEvaluableClassGoal,
                "a \(kind) target scopes no item set")
        }
        // The comparator: a union counts up, so only atLeast has a meaning the
        // progress bar can render.
        #expect(!unionGoal(comparator: .atMost).isSweepEvaluableClassGoal)
        #expect(!unionGoal(comparator: .equals).isSweepEvaluableClassGoal)
    }

    /// Arity stays at one. Admitting the union shape must not relax the rule
    /// that made the guard worth having.
    @Test func theSweepStillRefusesMultipleConditions() {
        let goal = Achievement(
            id: "u2", name: "Both", scope: .classWide,
            conditions: [
                AchievementCondition(signal: .itemsCovered, comparator: .atLeast, value: 12),
                AchievementCondition(signal: .grade, comparator: .atLeast, value: 50),
            ],
            reward: AchievementReward(type: .points, label: "Both", points: 5),
            classFraction: 0.6)
        #expect(!goal.isSweepEvaluableClassGoal)
    }

    /// `itemsCovered` reads the class, not a submission, so no per-submission
    /// evaluation may claim it holds — the unknown-signal convention.
    @Test func itemsCoveredIsNeverSatisfiedByOneSubmissionsSignals() {
        let condition = AchievementCondition(
            signal: .itemsCovered, comparator: .atLeast, value: 0)
        #expect(!condition.isSatisfied(by: AchievementSignals(gradePercent: 100)))
    }

    // MARK: - The full sweep (DB-backed)

    /// A four-variant bug hunt scoped to its "bugs" section, needing 3 of them
    /// and 50% of the roster.
    private func unionManifest(dueSoon: Bool = false) throws -> String {
        let props = TestProperties(
            testSuites: [
                TestSuiteEntry(tier: .secret, script: "variant_01.py", sectionID: "bugs"),
                TestSuiteEntry(tier: .secret, script: "variant_02.py", sectionID: "bugs"),
                TestSuiteEntry(tier: .secret, script: "variant_03.py", sectionID: "bugs"),
                TestSuiteEntry(tier: .pub, script: "wellformed.py", sectionID: "gate"),
            ],
            sections: [
                TestSuiteSection(id: "bugs", name: "Seeded bugs"),
                TestSuiteSection(id: "gate", name: "Well-formedness"),
            ],
            achievements: [
                Achievement(
                    id: "hunt", name: "Bug hunt", scope: .classWide,
                    conditions: [
                        AchievementCondition(
                            signal: .itemsCovered, comparator: .atLeast, value: 3,
                            target: AchievementTarget(kind: .section, ref: "bugs"))
                    ],
                    reward: AchievementReward(type: .points, label: "Bug hunt", points: 5),
                    classFraction: 0.5)
            ])
        return try #require(String(bytes: try JSONEncoder().encode(props), encoding: .utf8))
    }

    /// Coverage rows are written directly here rather than through
    /// `recordClassItemCoverage`: `ClassItemCoverageTests` owns the writer's
    /// behaviour, and one scenario below needs a row from a student who is no
    /// longer enrolled — which the writer refuses by design.
    private func cover(_ item: String, by userID: UUID, setupID: String, on db: Database) async throws {
        try await APIClassItemCoverage(
            testSetupID: setupID, item: item, userID: userID,
            submissionID: "\(setupID)_\(item)"
        ).save(on: db)
    }

    @Test func theSweepGradesAUnionGoalOnCoverageAndBreadth() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setup = APITestSetup(
                id: "un_setup", manifest: try unionManifest(),
                zipPath: app.testSetupsDirectory + "un_setup.zip", courseID: courseID)
            try await setup.save(on: app.db)
            _ = try await arInsertAssignment(
                testSetupID: "un_setup", title: "Union Lab", isOpen: true, on: app)

            let a = try await arInsertStudent(username: "un_a", on: app)
            try await arEnrollStudentInTestCourse(a, on: app)
            let b = try await arInsertStudent(username: "un_b", on: app)
            try await arEnrollStudentInTestCourse(b, on: app)
            let aID = try a.requireID()
            let bID = try b.requireID()

            // Two of three required variants, found by both students: coverage
            // 2/3, breadth 2/2 over a 50% target.
            try await cover("variant_01", by: aID, setupID: "un_setup", on: app.db)
            try await cover("variant_02", by: bID, setupID: "un_setup", on: app.db)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)

            let snapshot = try #require(
                try await APIAchievementResult.query(on: app.db)
                    .filter(\.$testSetupID == "un_setup").first())
            #expect(snapshot.itemsCovered == 2)
            #expect(snapshot.itemsRequired == 3)
            #expect(snapshot.studentsMeeting == 2, "both students contributed")
            #expect(snapshot.denominator == 2)
            #expect(snapshot.progress == 2.0 / 3.0, "coverage is the smaller half")
        }
    }

    /// Section scoping, end to end: the gate test passing is not a found bug,
    /// and counting it would hand the class a third of the goal for free.
    @Test func theSweepIgnoresCoverageOutsideTheGoalsSection() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setup = APITestSetup(
                id: "sec_setup", manifest: try unionManifest(),
                zipPath: app.testSetupsDirectory + "sec_setup.zip", courseID: courseID)
            try await setup.save(on: app.db)
            _ = try await arInsertAssignment(
                testSetupID: "sec_setup", title: "Section Lab", isOpen: true, on: app)

            let a = try await arInsertStudent(username: "sec_a", on: app)
            try await arEnrollStudentInTestCourse(a, on: app)
            let aID = try a.requireID()
            try await cover("variant_01", by: aID, setupID: "sec_setup", on: app.db)
            try await cover("wellformed", by: aID, setupID: "sec_setup", on: app.db)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)

            let snapshot = try #require(
                try await APIAchievementResult.query(on: app.db)
                    .filter(\.$testSetupID == "sec_setup").first())
            #expect(snapshot.itemsCovered == 1, "the gate test is not a seeded bug")
        }
    }

    /// The two halves scope differently on purpose, and this is the test that
    /// pins it: a student who dropped keeps the item they found (coverage must
    /// never retreat — it freezes into a grade push) but stops counting toward
    /// a fraction of the CURRENT roster (audit A7).
    @Test func aDroppedStudentsItemCountsButTheirBreadthDoesNot() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setup = APITestSetup(
                id: "drop_setup", manifest: try unionManifest(),
                zipPath: app.testSetupsDirectory + "drop_setup.zip", courseID: courseID)
            try await setup.save(on: app.db)
            _ = try await arInsertAssignment(
                testSetupID: "drop_setup", title: "Dropped Lab", isOpen: true, on: app)

            let enrolled = try await arInsertStudent(username: "drop_in", on: app)
            try await arEnrollStudentInTestCourse(enrolled, on: app)
            // Never enrolled — stands in for a student who has since dropped.
            let gone = try await arInsertStudent(username: "drop_out", on: app)

            try await cover(
                "variant_01", by: try enrolled.requireID(), setupID: "drop_setup", on: app.db)
            try await cover(
                "variant_02", by: try gone.requireID(), setupID: "drop_setup", on: app.db)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)

            let snapshot = try #require(
                try await APIAchievementResult.query(on: app.db)
                    .filter(\.$testSetupID == "drop_setup").first())
            #expect(snapshot.itemsCovered == 2, "both bugs are still found")
            #expect(snapshot.studentsMeeting == 1, "only the enrolled student counts for breadth")
            #expect(snapshot.denominator == 1)
        }
    }

    /// Slice 7, and the reason the snapshot stores its coverage: once the
    /// deadline freezes the row, later coverage must not move it — the bonus in
    /// every student's grade of record was computed from the frozen number.
    @Test func aFrozenUnionSnapshotIgnoresLaterCoverage() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setup = APITestSetup(
                id: "frzu_setup", manifest: try unionManifest(),
                zipPath: app.testSetupsDirectory + "frzu_setup.zip", courseID: courseID)
            try await setup.save(on: app.db)
            let assignment = try await arInsertAssignment(
                testSetupID: "frzu_setup", title: "Frozen Union Lab", isOpen: true, on: app)
            assignment.dueAt = Date().addingTimeInterval(-3600)
            try await assignment.save(on: app.db)

            let a = try await arInsertStudent(username: "frzu_a", on: app)
            try await arEnrollStudentInTestCourse(a, on: app)
            let aID = try a.requireID()
            try await cover("variant_01", by: aID, setupID: "frzu_setup", on: app.db)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)
            let frozen = try #require(
                try await APIAchievementResult.query(on: app.db)
                    .filter(\.$testSetupID == "frzu_setup").first())
            #expect(frozen.locked)
            #expect(frozen.itemsCovered == 1)

            // A late submission covers two more bugs.
            try await cover("variant_02", by: aID, setupID: "frzu_setup", on: app.db)
            try await cover("variant_03", by: aID, setupID: "frzu_setup", on: app.db)
            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)

            let after = try #require(
                try await APIAchievementResult.query(on: app.db)
                    .filter(\.$testSetupID == "frzu_setup").first())
            #expect(after.itemsCovered == 1, "a frozen snapshot is not recomputed")
            #expect(after.progress == frozen.progress)
        }
    }
}
