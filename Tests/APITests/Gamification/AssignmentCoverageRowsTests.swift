// Tests/APITests/Gamification/AssignmentCoverageRowsTests.swift
//
// The instructor's coverage section for a contribution assignment
// (`buildAssignmentCoverageRows`). The uncovered items are the point of the
// section, so the rows come from the suite and are left-joined onto the
// coverage table. These tests pin that join: suite order, an uncovered item
// keeps a row, a covered item whose suite entry is gone keeps its row, and a
// class composite lists its slots instead of its suite.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct AssignmentCoverageRowsTests {

    private func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }

    private func cover(
        _ item: String, setupID: String, by user: APIUser, on app: Application
    ) async throws {
        try await APIClassItemCoverage(
            testSetupID: setupID, item: item, userID: try user.requireID(), submissionID: "\(setupID)_\(item)"
        ).create(on: app.db)
    }

    private func suite(_ entries: [TestSuiteEntry]) -> TestProperties {
        TestProperties(testSuites: entries, language: .python)
    }

    // MARK: - The left join onto the suite

    @Test func everySuiteItemHasARowInSuiteOrderAndUncoveredItemsAreMarkedNotFound() async throws {
        try await withAssignmentRoutesApp { app in
            let setupID = "covrows_order"
            let finder = try await arInsertStudent(username: "covrows_order_a", on: app)
            try await cover("variant_02", setupID: setupID, by: finder, on: app)

            let manifest = suite([
                TestSuiteEntry(tier: .pub, script: "variant_03.py"),
                TestSuiteEntry(tier: .pub, script: "variant_01.py"),
                TestSuiteEntry(tier: .pub, script: "variant_02.py"),
            ])
            let rows = try await buildAssignmentCoverageRows(
                testSetupID: setupID, manifest: manifest, formatter: formatter(), on: app.db)

            #expect(rows.map(\.item) == ["variant_03", "variant_01", "variant_02"])
            #expect(rows.map(\.found) == [false, false, true])
            let uncovered = try #require(rows.first)
            #expect(uncovered.foundBy.isEmpty)
            #expect(uncovered.foundAt.isEmpty)
            #expect(uncovered.foundAtISO.isEmpty)
            #expect(assignmentCoverageSummary(rows) == "1 / 3 items found")
        }
    }

    /// A covered row names its first finder and carries the instant twice:
    /// once preformatted, once as ISO 8601 for the relative-time cell.
    @Test func aCoveredRowNamesTheFinderAndTheInstant() async throws {
        try await withAssignmentRoutesApp { app in
            let setupID = "covrows_finder"
            let finder = try await arInsertStudent(username: "covrows_finder_a", on: app)
            try await cover("variant_01", setupID: setupID, by: finder, on: app)
            let stored = try #require(try await classItemCoverage(testSetupID: setupID, on: app.db).first)
            let coveredAt = try #require(stored.coveredAt)

            let format = formatter()
            let rows = try await buildAssignmentCoverageRows(
                testSetupID: setupID,
                manifest: suite([TestSuiteEntry(tier: .pub, script: "variant_01.py")]),
                formatter: format, on: app.db)

            let row = try #require(rows.first)
            #expect(rows.count == 1)
            #expect(row.found)
            #expect(row.foundBy == "covrows_finder_a")
            #expect(row.foundAt == format.string(from: coveredAt))
            #expect(row.foundAtISO == iso8601String(coveredAt))
        }
    }

    /// The item name is the runner-stamped name: the display name when the
    /// entry has one, not the script stem.
    @Test func aSuiteEntryWithADisplayNameIsMatchedByThatName() async throws {
        try await withAssignmentRoutesApp { app in
            let setupID = "covrows_named"
            let finder = try await arInsertStudent(username: "covrows_named_a", on: app)
            try await cover("Off by one", setupID: setupID, by: finder, on: app)

            let rows = try await buildAssignmentCoverageRows(
                testSetupID: setupID,
                manifest: suite([TestSuiteEntry(tier: .pub, script: "variant_01.py", name: "Off by one")]),
                formatter: formatter(), on: app.db)

            #expect(rows.map(\.item) == ["Off by one"])
            #expect(rows.map(\.found) == [true])
        }
    }

    /// Dropping a covered item whose suite entry was deleted would quietly
    /// shrink the denominator, so it keeps a row, after the suite's items.
    @Test func aCoveredItemNoLongerInTheSuiteKeepsItsRowAtTheEnd() async throws {
        try await withAssignmentRoutesApp { app in
            let setupID = "covrows_orphan"
            let finder = try await arInsertStudent(username: "covrows_orphan_a", on: app)
            try await cover("variant_09", setupID: setupID, by: finder, on: app)

            let rows = try await buildAssignmentCoverageRows(
                testSetupID: setupID,
                manifest: suite([
                    TestSuiteEntry(tier: .pub, script: "variant_01.py"),
                    TestSuiteEntry(tier: .pub, script: "variant_02.py"),
                ]),
                formatter: formatter(), on: app.db)

            #expect(rows.map(\.item) == ["variant_01", "variant_02", "variant_09"])
            #expect(rows.map(\.found) == [false, false, true])
            #expect(rows.last?.foundBy == "covrows_orphan_a")
        }
    }

    /// With no manifest there is no suite to join onto, so the rows are the
    /// covered items alone, all found.
    @Test func withNoManifestTheRowsAreTheCoveredItems() async throws {
        try await withAssignmentRoutesApp { app in
            let setupID = "covrows_nomanifest"
            let finder = try await arInsertStudent(username: "covrows_nomanifest_a", on: app)
            try await cover("variant_02", setupID: setupID, by: finder, on: app)
            try await cover("variant_01", setupID: setupID, by: finder, on: app)

            let rows = try await buildAssignmentCoverageRows(
                testSetupID: setupID, manifest: nil, formatter: formatter(), on: app.db)

            #expect(rows.map(\.item) == ["variant_01", "variant_02"])
            #expect(rows.map(\.found) == [true, true])
        }
    }

    /// A finder whose account cannot be read is shown as "unknown", not as a
    /// blank that reads as "nobody".
    @Test func aFinderWithNoAccountIsShownAsUnknown() async throws {
        try await withAssignmentRoutesApp { app in
            let setupID = "covrows_unknown"
            try await APIClassItemCoverage(
                testSetupID: setupID, item: "variant_01", userID: UUID(), submissionID: "covrows_unknown_s1"
            ).create(on: app.db)

            let rows = try await buildAssignmentCoverageRows(
                testSetupID: setupID,
                manifest: suite([TestSuiteEntry(tier: .pub, script: "variant_01.py")]),
                formatter: formatter(), on: app.db)

            #expect(rows.map(\.foundBy) == ["unknown"])
        }
    }

    /// Coverage of another assignment does not open this assignment's section.
    @Test func anotherAssignmentsCoverageGivesNoRows() async throws {
        try await withAssignmentRoutesApp { app in
            let finder = try await arInsertStudent(username: "covrows_other_a", on: app)
            try await cover("variant_01", setupID: "covrows_other_elsewhere", by: finder, on: app)

            let rows = try await buildAssignmentCoverageRows(
                testSetupID: "covrows_other_here",
                manifest: suite([TestSuiteEntry(tier: .pub, script: "variant_01.py")]),
                formatter: formatter(), on: app.db)

            #expect(rows.isEmpty)
        }
    }

    // MARK: - A class composite lists its slots

    @Test func aClassCompositeListsItsSlotsInsteadOfItsSuite() async throws {
        try await withAssignmentRoutesApp { app in
            let setupID = "covrows_composite"
            let finder = try await arInsertStudent(username: "covrows_composite_a", on: app)
            try await cover("slot-2", setupID: setupID, by: finder, on: app)

            let spec = CompositeSpec(
                compositor: .tile, layout: .grid(columns: 2, rows: 2),
                contribution: CompositeContributionShape(width: 4, height: 4, frames: 1, format: .gray8),
                dealOrder: .rowMajor)
            let manifest = TestProperties(
                testSuites: [TestSuiteEntry(tier: .pub, script: "tile.py")],
                language: .python,
                activity: ClassActivity(kind: .classComposite, composite: spec))

            let rows = try await buildAssignmentCoverageRows(
                testSetupID: setupID, manifest: manifest, formatter: formatter(), on: app.db)

            #expect(rows.map(\.item) == ["slot-0", "slot-1", "slot-2", "slot-3"])
            #expect(rows.map(\.found) == [false, false, true, false])
        }
    }

    // MARK: - The class-corpus wording

    /// Whole percents, rounded to nearest, for both the share and the goal.
    @Test(arguments: [
        (61.6, 80.0, "62% / 80% covered"),
        (61.4, 79.5, "61% / 80% covered"),
        (0.0, 100.0, "0% / 100% covered"),
        (99.5, 50.2, "100% / 50% covered"),
    ])
    func corpusCoverageSummaryRoundsToWholePercents(percent: Double, required: Double, expected: String) {
        #expect(corpusCoverageSummary(percent: percent, required: required) == expected)
    }
}
