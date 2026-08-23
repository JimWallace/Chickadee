// Tests/APITests/AchievementAuthoringTests.swift
//
// Class-goal authoring through the unified Achievements editor: PUT
// /instructor/:id/achievements persists class goals into the assignment
// manifest (and GET reads them back as editable rows). Display-only, so the
// save does not retest or re-validate.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct AchievementAuthoringTests {

    private func classGoalRow(
        name: String, thresholdPercent: Double, classPercent: Double, points: Int
    ) -> PublishedAssignmentRoutes.AchievementInput {
        .init(
            id: nil, name: name, detail: nil, scope: "classWide", match: "all",
            conditions: [
                .init(signal: "grade", comparator: "atLeast", value: thresholdPercent, testRef: nil)
            ],
            classPercent: classPercent, points: points, recordDimension: nil)
    }

    @Test func putAndGetClassGoalsRoundTrip() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "cga_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "cga_setup", title: "Goals", isOpen: true, on: app)

            try await app.asyncTest(
                .PUT, "/instructor/\(assignment.publicID)/achievements",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    try req.content.encode(
                        PublishedAssignmentRoutes.AchievementsBody(achievements: [
                            classGoalRow(
                                name: "80% Mastery", thresholdPercent: 80, classPercent: 80, points: 5)
                        ]), as: .json)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                })

            // The manifest now carries the class goal, encoded as an Achievement.
            let setup = try #require(try await APITestSetup.find("cga_setup", on: app.db))
            let props = try JSONDecoder().decode(
                TestProperties.self, from: Data(setup.manifest.utf8))
            let goal = try #require(props.achievements.first { $0.isClassGoal })
            #expect(goal.name == "80% Mastery")
            #expect(goal.scope == .classWide)
            #expect(goal.gradeThresholdFraction == 0.8)
            #expect(goal.classFraction == 0.8)
            #expect(goal.reward.type == .points)
            #expect(goal.reward.points == 5)

            // GET returns it as an editable row (percent units back out).
            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/achievements",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("80% Mastery"))
                    #expect(body.contains("\"signal\":\"grade\""))
                })
        }
    }

    // MARK: - Union class goals (itemsCovered)

    /// A four-test suite in two sections, the shape a bug hunt has: seeded
    /// variants in one section, the well-formedness gate in another.
    private func bugHuntManifest() throws -> String {
        let props = TestProperties(
            testSuites: [
                TestSuiteEntry(tier: .secret, script: "variant_01.py", sectionID: "bugs"),
                TestSuiteEntry(tier: .pub, script: "wellformed.py", sectionID: "gate"),
            ],
            sections: [
                TestSuiteSection(id: "bugs", name: "Seeded bugs"),
                TestSuiteSection(id: "gate", name: "Well-formedness"),
            ])
        return try #require(String(bytes: try JSONEncoder().encode(props), encoding: .utf8))
    }

    private func unionRow(sectionRef: String?) -> AchievementRow {
        AchievementRow(
            name: "Bug hunt", scope: "classWide", match: "all",
            conditions: [
                ConditionRow(
                    signal: "itemsCovered", comparator: "atLeast", value: 3,
                    sectionRef: sectionRef)
            ],
            classPercent: 60, points: 5)
    }

    @Test func aUnionGoalSavesAndRoundTripsItsSection() throws {
        let achievement = try AchievementsEditing.achievement(from: unionRow(sectionRef: "bugs"))
        #expect(achievement.isUnionClassGoal)
        let requirement = try #require(achievement.coveredItemsRequirement)
        #expect(requirement.count == 3)
        #expect(requirement.scope?.kind == .section)
        #expect(requirement.scope?.ref == "bugs")
        // Back out to the editor row, which is what the UI and MCP read.
        #expect(AchievementsEditing.row(from: achievement).conditions?.first?.sectionRef == "bugs")
    }

    /// No section named means the whole suite, so the target stays nil rather
    /// than becoming a `.section` pointing at nothing — a shape the sweep would
    /// then refuse.
    @Test func aUnionGoalWithNoSectionCountsTheWholeSuite() throws {
        let achievement = try AchievementsEditing.achievement(from: unionRow(sectionRef: nil))
        #expect(achievement.coveredItemsRequirement?.scope == nil)
        #expect(achievement.isSweepEvaluableClassGoal)
    }

    /// The A1/A17 shape, one signal over: a section ref that resolves to
    /// nothing scopes the union to an empty item set, so the goal would sit at
    /// 0% forever with no error anywhere.
    @Test func saveRefusesASectionRefThatMatchesNoSuiteSection() throws {
        let achievement = try AchievementsEditing.achievement(from: unionRow(sectionRef: "typo"))
        #expect(throws: WebAssignmentError.self) {
            try AchievementsEditing.validate([achievement], againstManifest: try bugHuntManifest())
        }
        // The same goal against a real section saves.
        let good = try AchievementsEditing.achievement(from: unionRow(sectionRef: "bugs"))
        try AchievementsEditing.validate([good], againstManifest: try bugHuntManifest())
    }

    /// A section id is an opaque UUID no page displays, so an MCP agent writing
    /// the row as JSON can only know the NAME. Asking it for a value it has no
    /// way to obtain is how a ref goes unset; the name resolves on save.
    @Test func aSectionNamedByItsLabelResolvesToItsID() throws {
        let authored = try AchievementsEditing.achievement(from: unionRow(sectionRef: "Seeded bugs"))
        let resolved = AchievementsEditing.resolvingSectionRefs(
            authored, againstManifest: try bugHuntManifest())
        #expect(resolved.coveredItemsRequirement?.scope?.ref == "bugs")
        try AchievementsEditing.validate([resolved], againstManifest: try bugHuntManifest())
    }

    /// An id is left alone — resolution must not turn a correct ref into a
    /// name lookup that happens to miss.
    @Test func aSectionNamedByItsIDIsUnchanged() throws {
        let authored = try AchievementsEditing.achievement(from: unionRow(sectionRef: "bugs"))
        let resolved = AchievementsEditing.resolvingSectionRefs(
            authored, againstManifest: try bugHuntManifest())
        #expect(resolved.coveredItemsRequirement?.scope?.ref == "bugs")
    }

    /// The silent-never-fires shape this signal newly makes reachable: an
    /// `itemsCovered` condition on a per-student badge cannot be evaluated per
    /// submission, so it would save cleanly and never fire for anyone. The
    /// editor hides the option off-scope; MCP writes JSON and has no dropdown,
    /// so the refusal is here.
    @Test func saveRefusesAClassReadingSignalOutsideAClassGoal() {
        for scope in ["individual", "record"] {
            let row = AchievementRow(
                name: "Bug Hunter", scope: scope, match: "all",
                conditions: [
                    ConditionRow(signal: "itemsCovered", comparator: "atLeast", value: 3)
                ],
                recordDimension: "firstToSolve")
            #expect(throws: WebAssignmentError.self) {
                try AchievementsEditing.achievement(from: row)
            }
        }
    }

    /// The editor derives which signals it may offer from the same fact, so the
    /// dropdown and the refusal cannot disagree.
    @Test func onlyClassWideOffersAClassReadingSignal() throws {
        for option in AchievementSignalPresentation.all {
            let signal = try #require(AchievementSignal(rawValue: option.value))
            #expect(
                option.scopes == signal.allowedScopes.map(\.rawValue).joined(separator: " "),
                "\(option.value) offers scopes the save would refuse")
        }
        let covered = try #require(
            AchievementSignalPresentation.all.first { $0.value == AchievementSignal.itemsCovered.rawValue })
        #expect(covered.scopes == AchievementScope.classWide.rawValue)
    }

    /// Admitting the union shape must not relax the arity that makes the
    /// authoring guard worth having (audit A4).
    @Test func saveStillRefusesAClassGoalTheSweepCannotEvaluate() {
        var row = unionRow(sectionRef: "bugs")
        row.conditions?.append(ConditionRow(signal: "grade", comparator: "atLeast", value: 50))
        #expect(throws: WebAssignmentError.self) {
            try AchievementsEditing.achievement(from: row)
        }
    }

    @Test func putRejectsOutOfRangeThreshold() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "cga_bad_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "cga_bad_setup", title: "Bad Goals", isOpen: true, on: app)

            try await app.asyncTest(
                .PUT, "/instructor/\(assignment.publicID)/achievements",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    try req.content.encode(
                        PublishedAssignmentRoutes.AchievementsBody(achievements: [
                            classGoalRow(
                                name: "Impossible", thresholdPercent: 150, classPercent: 80, points: 5)
                        ]), as: .json)
                },
                afterResponse: { res in
                    #expect(res.status != .ok, "Out-of-range threshold must be rejected")
                })

            let setup = try #require(try await APITestSetup.find("cga_bad_setup", on: app.db))
            let props = try JSONDecoder().decode(
                TestProperties.self, from: Data(setup.manifest.utf8))
            #expect(props.achievements.isEmpty, "Rejected goal must not be written")
        }
    }
}
