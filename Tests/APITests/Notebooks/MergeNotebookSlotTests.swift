// Coverage for contribution slots — the server-side bound on how much of a
// student's notebook counts as their contribution.
//
// The property under test is deliberately NOT "the editor stopped them". A
// student can add cells, reorder them, edit an `.ipynb` offline and upload it,
// or delete a slot marker; `mergeNotebook` is where every one of those paths
// converges, so the bound is asserted there against notebooks shaped the way
// each of those students would produce.
//
// The back-compat case matters as much as the feature: an assignment that
// declares no slots must go through this path unchanged, or every existing
// notebook assignment silently loses its solution cells.

import Foundation
import Testing

@testable import APIServer

@Suite struct MergeNotebookSlotTests {

    // MARK: - Fixtures

    private func cell(_ source: String, slot: String? = nil) -> [String: Any] {
        var metadata: [String: Any] = [:]
        if let slot { metadata[NotebookContributionSlots.slotMetadataKey] = slot }
        return [
            "cell_type": "code", "metadata": metadata,
            "execution_count": NSNull(), "outputs": [],
            "source": [source],
        ]
    }

    private func testCell(_ name: String) -> [String: Any] {
        [
            "cell_type": "code", "metadata": [:],
            "execution_count": NSNull(), "outputs": [],
            "source": ["# TEST: tier=secret\n", "assert \(name)\n"],
        ]
    }

    private func notebook(_ cells: [[String: Any]]) -> Data {
        let obj: [String: Any] = [
            "nbformat": 4, "nbformat_minor": 5, "metadata": [:], "cells": cells,
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    private func sources(of data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
            let dict = obj as? [String: Any],
            let cells = dict["cells"] as? [[String: Any]]
        else { return [] }
        return cells.map { cell in
            if let arr = cell["source"] as? [String] { return arr.joined() }
            return (cell["source"] as? String) ?? ""
        }
    }

    /// An instructor notebook declaring `count` slots plus one hidden test.
    private func instructorWithSlots(_ count: Int) -> Data {
        var cells: [[String: Any]] = []
        for index in 1...max(count, 1) where count > 0 {
            cells.append(cell("# write your test here\n", slot: "\(index)"))
        }
        cells.append(testCell("True"))
        return notebook(cells)
    }

    // MARK: - The bound

    @Test func keepsOnlyWhatTheStudentWroteInSlots() {
        let student = notebook([
            cell("test_one()\n", slot: "1"),
            cell("scratch work\n"),
            cell("test_two()\n", slot: "2"),
        ])
        let merged = mergeNotebook(student: student, instructor: instructorWithSlots(3))
        let kept = sources(of: merged)
        #expect(kept.contains("test_one()\n"))
        #expect(kept.contains("test_two()\n"))
        #expect(
            !kept.contains("scratch work\n"),
            "A cell outside a slot must not reach grading — otherwise the bound is bypassable.")
    }

    /// The bypass this bound exists to close: a student who puts twenty tests in
    /// cells beyond their allotted slots contributes only the first three.
    @Test func capsSlotCellsAtTheDeclaredCount() {
        var cells: [[String: Any]] = []
        for index in 1...20 { cells.append(cell("test_\(index)()\n", slot: "\(index)")) }
        let merged = mergeNotebook(student: notebook(cells), instructor: instructorWithSlots(3))
        let kept = sources(of: merged).filter { $0.hasPrefix("test_") }
        #expect(kept.count == 3, "Expected 3 slot cells, got \(kept.count)")
        #expect(kept == ["test_1()\n", "test_2()\n", "test_3()\n"], "Cap must take document order")
    }

    /// An offline-edited upload is the path no editor rule can reach, so it is
    /// the one that proves the bound is real rather than cosmetic.
    @Test func anOfflineEditedUploadIsBoundedTheSameWay() {
        var cells = [cell("test_a()\n", slot: "1")]
        for index in 1...50 { cells.append(cell("sneaky_\(index)()\n")) }
        let merged = mergeNotebook(student: notebook(cells), instructor: instructorWithSlots(3))
        let kept = sources(of: merged)
        #expect(kept.contains("test_a()\n"))
        #expect(!kept.contains { $0.hasPrefix("sneaky_") })
    }

    /// Deleting the marker loses the slot rather than smuggling the cell
    /// through. Legible, self-inflicted, and recoverable by resetting the
    /// starter — the alternative (treating unmarked cells as slots) is the
    /// bypass again.
    @Test func aCellWithItsMarkerRemovedIsNotASlot() {
        let student = notebook([cell("test_one()\n"), cell("test_two()\n", slot: "2")])
        let merged = mergeNotebook(student: student, instructor: instructorWithSlots(3))
        let kept = sources(of: merged)
        #expect(!kept.contains("test_one()\n"))
        #expect(kept.contains("test_two()\n"))
    }

    @Test func slotOrderFollowsTheStudentsDocumentNotTheLabel() {
        let student = notebook([
            cell("second\n", slot: "2"),
            cell("first\n", slot: "1"),
        ])
        let merged = mergeNotebook(student: student, instructor: instructorWithSlots(1))
        #expect(sources(of: merged).first == "second\n")
    }

    // MARK: - The instructor's cells still win

    @Test func instructorTestCellsAreStillReimposed() {
        let student = notebook([
            cell("test_one()\n", slot: "1"),
            testCell("False"),  // a student-authored "test" cell
        ])
        let merged = mergeNotebook(student: student, instructor: instructorWithSlots(2))
        let kept = sources(of: merged)
        #expect(kept.contains { $0.contains("assert True") }, "instructor test must be present")
        #expect(!kept.contains { $0.contains("assert False") }, "student test cell must be dropped")
    }

    // MARK: - Back-compat: an assignment with no slots is untouched

    /// The case that would break every existing notebook assignment if the
    /// bound applied unconditionally: with no slots declared, nothing is
    /// dropped.
    @Test func anAssignmentDeclaringNoSlotsKeepsEveryStudentCell() {
        let student = notebook([
            cell("import pandas as pd\n"),
            cell("def solution():\n    return 42\n"),
            cell("solution()\n"),
        ])
        let instructor = notebook([cell("# starter\n"), testCell("True")])
        let merged = mergeNotebook(student: student, instructor: instructor)
        let kept = sources(of: merged)
        #expect(kept.contains("import pandas as pd\n"))
        #expect(kept.contains("def solution():\n    return 42\n"))
        #expect(kept.contains("solution()\n"))
    }

    @Test func aStudentWhoWroteNothingInAnySlotContributesNothing() {
        let student = notebook([cell("nothing marked\n")])
        let merged = mergeNotebook(student: student, instructor: instructorWithSlots(3))
        let kept = sources(of: merged)
        #expect(!kept.contains("nothing marked\n"))
        #expect(kept.contains { $0.contains("assert True") }, "grading still runs")
    }

    // MARK: - Marker shapes

    @Test func anEmptyStringMarkerDoesNotDeclareASlot() {
        #expect(!NotebookContributionSlots.isSlotCell(cell("x\n", slot: "")))
        #expect(NotebookContributionSlots.isSlotCell(cell("x\n", slot: "1")))
    }

    @Test func aNonStringMarkerStillCountsAsASlot() {
        let numeric: [String: Any] = [
            "cell_type": "code",
            "metadata": [NotebookContributionSlots.slotMetadataKey: 2],
            "source": ["x\n"],
        ]
        #expect(NotebookContributionSlots.isSlotCell(numeric))
    }
}
