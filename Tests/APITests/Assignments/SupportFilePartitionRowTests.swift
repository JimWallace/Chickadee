// Tests/APITests/Assignments/SupportFilePartitionRowTests.swift
//
// The Files panel shows a partition dataset as a note, not as sample fields
// (docs/datasets-course-library.md §4.11). The part count reaches the row from
// the manifest, and the rendered row hides the sample fields and names the
// part count.

import Core
import Elementary
import Foundation
import Testing

@testable import APIServer

@Suite struct SupportFilePartitionRowTests {

    private func row(partCount: Int?) -> EditableSuiteRow {
        EditableSuiteRow(
            name: "cases.csv", url: "/f", isTest: false, tier: "support", order: 1, dependsOn: [], points: 1,
            displayName: nil, isDataset: true, datasetSampleSize: partCount == nil ? 25 : nil,
            datasetPartCount: partCount)
    }

    @Test func theRowBuilderCarriesThePartCount() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("support-file-partition-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zipPath = root.appendingPathComponent("setup.zip").path
        try await ahMakeZip(
            at: zipPath, entries: [("cases.csv", "id\n1\n2\n3\n"), ("publictest_a.py", "print('ok')")])
        var props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "publictest_a.py")], language: .python)
        props.datasets = [DatasetSpec(file: "cases.csv", kind: .partition, partCount: 3)]
        let setup = APITestSetup(
            id: "setup_pt", manifest: try encodeManifest(props), zipPath: zipPath, courseID: UUID())

        let rows = await currentSetupFiles(for: setup, assignmentID: "asg123", solutionFilename: nil)
            .existingSuiteRows
        let dataset = try #require(rows.first { $0.name == "cases.csv" })
        #expect(dataset.isDataset)
        #expect(dataset.datasetPartCount == 3)
    }

    /// The opening tag of the element whose class list holds `className`.
    private func openingTag(of className: String, in html: String) throws -> Substring {
        let mark = try #require(html.range(of: className))
        let start = try #require(html[..<mark.lowerBound].range(of: "<", options: .backwards))
        let end = try #require(html[mark.upperBound...].range(of: ">"))
        return html[start.lowerBound..<end.upperBound]
    }

    @Test func aPartitionRowShowsTheNoteAndHidesTheSampleFields() throws {
        let html = SupportFileRow(file: row(partCount: 3)).render()
        #expect(
            html.contains("Split into <span class=\"js-dataset-part-count\">3</span> parts, dealt to students in turn"))
        // A partition is not a sample, so the toggle does not call it one.
        #expect(html.contains("Per-student data"))
        #expect(!html.contains("Per-student sample"))
        #expect(!(try openingTag(of: "js-dataset-partition-note", in: html)).contains("hidden"))
        #expect(try openingTag(of: "js-dataset-size-field", in: html).contains("hidden"))
        // One click must not end a partition, and the lock is not an
        // attached file's, so the panel may lift it.
        let toggle = try openingTag(of: "js-dataset-toggle", in: html)
        #expect(toggle.contains("disabled"))
        #expect(!toggle.contains("data-lock"))
    }

    /// The note is always rendered, hidden, so the panel can show it when a
    /// spec becomes a partition after the page loads.
    @Test func aSampledRowHidesTheNoteAndKeepsItsToggle() throws {
        let html = SupportFileRow(file: row(partCount: nil)).render()
        #expect(try openingTag(of: "js-dataset-partition-note", in: html).contains("hidden"))
        #expect(html.contains("Per-student data"))
        #expect(!(try openingTag(of: "js-dataset-toggle", in: html)).contains("disabled"))
    }

    /// The upload page names a student's file by what they hold.
    @Test func theUploadPageNamesAPartitionAsOnePart() {
        let partition = SubmitDatasetLink(
            spec: DatasetSpec(file: "cases.csv", kind: .partition, partCount: 4), setupID: "s1")
        #expect(partition.rowsText == "one part of 4")
        let shared = SubmitDatasetLink(spec: DatasetSpec(file: "cases.csv"), setupID: "s1")
        #expect(shared.rowsText == "every row")
    }
}
