// Tests/APITests/Gamification/ClassItemCoveragePlainDatabaseTests.swift
//
// The store-agnostic path of the coverage accumulators: a database that does
// not conform to `SQLDatabase` gets one query for the items already held and
// one insert per new item, not the single `ON CONFLICT DO NOTHING` statement.
// It must keep the same rules as the SQL path: the first finder keeps an item,
// a replay inserts nothing, a repeated item in one submission is one row, and
// a lab's coverage is counted apart from another lab's.

import Core
import Fluent
import Foundation
import NIOCore
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct ClassItemCoveragePlainDatabaseTests {

    private func passing(_ names: [String]) -> [TestOutcome] {
        names.map { TestOutcome.stub($0, status: .pass) }
    }

    @Test func theClassUnionKeepsTheFirstFinderOnAPlainDatabase() async throws {
        try await withTestApp { app in
            let scenario = try await TestScenario.make(
                on: app, setupID: "cicp_class", manifest: TestManifests.emptySuite, withNotebook: false)
            let ada = try await scenario.enroll("cicp_ada", on: app)
            let ben = try await scenario.enroll("cicp_ben", on: app)
            let plain = ForwardingTestDatabase(base: app.db)

            try await recordClassItemCoverage(
                testSetupID: scenario.setupID, userID: ada, submissionID: "cicp_s1",
                outcomes: passing(["item_a", "item_b", "item_a"]), declaredSlotCount: 3, on: plain)
            try await recordClassItemCoverage(
                testSetupID: scenario.setupID, userID: ben, submissionID: "cicp_s2",
                outcomes: passing(["item_b", "item_c"]), declaredSlotCount: 3, on: plain)
            // A replay of the first submission inserts nothing.
            try await recordClassItemCoverage(
                testSetupID: scenario.setupID, userID: ada, submissionID: "cicp_s1",
                outcomes: passing(["item_a", "item_b"]), declaredSlotCount: 3, on: plain)

            let rows = try await classItemCoverage(testSetupID: scenario.setupID, on: app.db)
            #expect(rows.map(\.item) == ["item_a", "item_b", "item_c"])
            #expect(rows.map(\.userID) == [ada, ada, ben])
            #expect(rows.map(\.submissionID) == ["cicp_s1", "cicp_s1", "cicp_s2"])
        }
    }

    @Test func aLabKeepsItsFirstFinderOnAPlainDatabase() async throws {
        try await withTestApp { app in
            let scenario = try await TestScenario.make(
                on: app, setupID: "cicp_lab", manifest: TestManifests.emptySuite, withNotebook: false)
            let set = try await CourseGroupStore.createSet(courseID: scenario.courseID, name: "Labs", on: app.db)
            let labA = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db).requireID()
            let labB = try await CourseGroupStore.addGroup(named: "Lab 102", to: set, on: app.db).requireID()
            let ada = try await scenario.enroll("cicp_lab_ada", on: app)
            let ben = try await scenario.enroll("cicp_lab_ben", on: app)
            let plain = ForwardingTestDatabase(base: app.db)

            try await recordLabItemCoverage(
                testSetupID: scenario.setupID, groupID: labA, items: ["item_a"], userID: ada,
                submissionID: "first", on: plain)
            try await recordLabItemCoverage(
                testSetupID: scenario.setupID, groupID: labA, items: ["item_a", "item_b"], userID: ben,
                submissionID: "second", on: plain)
            try await recordLabItemCoverage(
                testSetupID: scenario.setupID, groupID: labB, items: ["item_a"], userID: ben,
                submissionID: "second", on: plain)

            let byLab = try await labItemCoverage(testSetupID: scenario.setupID, on: app.db)
            let labARows = (byLab[labA] ?? []).sorted { $0.item < $1.item }
            #expect(labARows == [CoveredItem(item: "item_a", userID: ada), CoveredItem(item: "item_b", userID: ben)])
            #expect(byLab[labB] == [CoveredItem(item: "item_a", userID: ben)], "each lab counts its own coverage")
            #expect(try await APIClassItemCoverage.query(on: app.db).count() == 0, "no whole-class coverage")
        }
    }
}
