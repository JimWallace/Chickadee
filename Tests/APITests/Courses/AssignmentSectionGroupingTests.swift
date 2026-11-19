// Tests/APITests/Courses/AssignmentSectionGroupingTests.swift
//
// `groupRowsBySection` and `assignmentDisplayOrderPrecedes` are the one
// grouping fold and the one order rule for every page that lists a course's
// assignments (#1118). The page tests reach them through the database. Two
// paths had no direct test: the grouping of rows into sections, with or
// without empty sections, and the last tie-break of the order rule (the setup
// id, when the sort order and the creation date are equal).

import Foundation
import Testing

@testable import APIServer

@Suite struct AssignmentSectionGroupingTests {

    private struct Row: Equatable {
        let name: String
        let sectionID: UUID?
    }

    private let courseID = UUID()

    private func group(
        _ rows: [Row], sections: [APICourseSection], includeEmpty: Bool
    ) -> (sections: [String], ungrouped: [String]) {
        let result = groupRowsBySection(
            rows: rows, sections: sections, includeEmptySections: includeEmpty,
            sectionIDForRow: \.sectionID,
            makeSection: { section, rows in "\(section.name): \(rows.map(\.name).joined(separator: ","))" })
        return (result.sections, result.ungrouped.map(\.name))
    }

    @Test func rowsAreGroupedInTheGivenSectionArrayOrderAndKeepTheirOwnOrder() {
        // The fold follows the array, not `sortOrder`: the caller sorts.
        let labs = APICourseSection(id: UUID(), name: "Labs", sortOrder: 2, courseID: courseID)
        let exams = APICourseSection(id: UUID(), name: "Exams", sortOrder: 1, courseID: courseID)
        let rows = [
            Row(name: "exam1", sectionID: exams.id),
            Row(name: "lab2", sectionID: labs.id),
            Row(name: "intro", sectionID: nil),
            Row(name: "lab1", sectionID: labs.id),
        ]
        let result = group(rows, sections: [labs, exams], includeEmpty: false)
        #expect(result.sections == ["Labs: lab2,lab1", "Exams: exam1"])
        #expect(result.ungrouped == ["intro"])
    }

    @Test func anEmptySectionIsShownOnlyWhenAsked() {
        let labs = APICourseSection(id: UUID(), name: "Labs", sortOrder: 1, courseID: courseID)
        let empty = APICourseSection(id: UUID(), name: "Empty", sortOrder: 2, courseID: courseID)
        let rows = [Row(name: "lab1", sectionID: labs.id)]
        #expect(group(rows, sections: [labs, empty], includeEmpty: false).sections == ["Labs: lab1"])
        #expect(group(rows, sections: [labs, empty], includeEmpty: true).sections == ["Labs: lab1", "Empty: "])
    }

    @Test func aRowInAnUnknownSectionAndASectionWithNoIDAreDropped() {
        // Deliberate (see the function's doc comment): a stale section id is
        // normalized away at write time, so every original page dropped it.
        let labs = APICourseSection(id: UUID(), name: "Labs", sortOrder: 1, courseID: courseID)
        let unsaved = APICourseSection(name: "Unsaved", sortOrder: 2, courseID: courseID)
        let rows = [Row(name: "lab1", sectionID: labs.id), Row(name: "stale", sectionID: UUID())]
        let result = group(rows, sections: [labs, unsaved], includeEmpty: true)
        #expect(result.sections == ["Labs: lab1"])
        #expect(result.ungrouped.isEmpty)
    }

    // MARK: - Display order

    @Test func theSetupIDBreaksATieOnOrderAndDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            assignmentDisplayOrderPrecedes(
                lhsSortOrder: 3, rhsSortOrder: 3, lhsCreatedAt: date, rhsCreatedAt: date,
                lhsSetupID: "setup_a", rhsSetupID: "setup_b"))
        #expect(
            !assignmentDisplayOrderPrecedes(
                lhsSortOrder: 3, rhsSortOrder: 3, lhsCreatedAt: date, rhsCreatedAt: date,
                lhsSetupID: "setup_b", rhsSetupID: "setup_a"))
        // Two missing dates are equal too, so the id decides.
        #expect(
            assignmentDisplayOrderPrecedes(
                lhsSortOrder: nil, rhsSortOrder: nil, lhsCreatedAt: nil, rhsCreatedAt: nil,
                lhsSetupID: "setup_a", rhsSetupID: "setup_b"))
    }

    @Test func aDifferentSortOrderWinsAndANilSortOrderFallsToTheNewerDate() {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = older.addingTimeInterval(60)
        #expect(
            assignmentDisplayOrderPrecedes(
                lhsSortOrder: 1, rhsSortOrder: 2, lhsCreatedAt: older, rhsCreatedAt: newer,
                lhsSetupID: "setup_z", rhsSetupID: "setup_a"))
        #expect(
            assignmentDisplayOrderPrecedes(
                lhsSortOrder: nil, rhsSortOrder: 2, lhsCreatedAt: newer, rhsCreatedAt: older,
                lhsSetupID: "setup_z", rhsSetupID: "setup_a"))
    }
}
