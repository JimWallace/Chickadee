// Tests/APITests/SupportFileDatasetRowTests.swift
//
// The Files panel's per-student dataset control renders from the support-file
// rows, so the dataset mark has to survive every step between the manifest and
// the template: both row builders (edit page and create page), the create
// page's URL rewrite, and `EditableSuiteRow`'s hand-written `encode(to:)` —
// which is where a new field silently fails to reach Leaf, because a row that
// encodes without it renders as an unmarked control rather than as an error.
//
// The marks themselves come from `TestProperties.datasetSpecsByFile`, the one
// lookup `get_support_files` reads, so the UI and the MCP listing cannot report
// different states for the same file (docs/datasets.md Phase 1).

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct SupportFileDatasetRowTests {

    /// A setup bundling one marked dataset (`cases.csv`, 25 rows), one plain
    /// support file, and one graded script.
    private func makeSetup(in directory: URL) throws -> APITestSetup {
        let zipPath = directory.appendingPathComponent("setup.zip").path
        try ahMakeZip(
            at: zipPath,
            entries: [
                ("assignment.ipynb", "{}"),
                ("cases.csv", "id\n1\n2\n3\n"),
                ("notes.txt", "notes"),
                ("publictest_a.py", "print('ok')"),
            ])
        return APITestSetup(
            id: "setup_ds",
            manifest: """
                {
                  "schemaVersion": 1,
                  "gradingMode": "worker",
                  "requiredFiles": [],
                  "testSuites": [{"tier":"public","script":"publictest_a.py"}],
                  "datasets": [{"file":"cases.csv","kind":"rowSample","sampleSize":25}],
                  "timeLimitSeconds": 10,
                  "makefile": null
                }
                """,
            zipPath: zipPath,
            courseID: UUID())
    }

    private func withSetup(_ body: (APITestSetup) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("support-file-dataset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(try makeSetup(in: root))
    }

    // MARK: - The edit page's rows

    @Test func currentSetupFilesMarksTheDatasetRowOnly() throws {
        try withSetup { setup in
            let rows = currentSetupFiles(
                for: setup, assignmentID: "asg123", solutionFilename: nil
            ).existingSuiteRows

            let dataset = try #require(rows.first { $0.name == "cases.csv" })
            #expect(dataset.isDataset)
            #expect(dataset.datasetSampleSize == 25)
            #expect(dataset.datasetSampleSizeText == "25")

            let plain = try #require(rows.first { $0.name == "notes.txt" })
            #expect(plain.isDataset == false)
            #expect(plain.datasetSampleSize == nil)
            #expect(plain.datasetSampleSizeText.isEmpty)

            // A graded script is never a dataset, whatever the manifest says.
            let script = try #require(rows.first { $0.name == "publictest_a.py" })
            #expect(script.isDataset == false)
        }
    }

    // MARK: - The create page's rows

    @Test func draftRowsCarryTheMarkThroughTheURLRewrite() throws {
        try withSetup { setup in
            let base = editableSuiteRowsForSetup(setup)
            let baseDataset = try #require(base.first { $0.name == "cases.csv" })
            #expect(baseDataset.isDataset)
            #expect(baseDataset.datasetSampleSize == 25)

            // The create page rebuilds support rows purely to point `url` at
            // the draft-scoped download; the mark must survive that copy.
            let rewritten = DraftAssignmentRoutes().newAssignmentSupportFileRows(
                setup: setup, suiteRows: base)
            let row = try #require(rewritten.first { $0.name == "cases.csv" })
            #expect(row.isDataset)
            #expect(row.datasetSampleSize == 25)
            #expect(row.url.contains("/instructor/new/draft/files/item"))
            #expect(rewritten.first { $0.name == "notes.txt" }?.isDataset == false)
        }
    }

    // MARK: - What Leaf actually receives

    @Test func encodedRowExposesTheDatasetFieldsToLeaf() throws {
        let row = EditableSuiteRow(
            name: "cases.csv", url: "#", isTest: false, tier: "support", order: 1,
            dependsOn: [], points: 1, displayName: nil,
            isDataset: true, datasetSampleSize: 25)
        let encoded = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(row))
        let dict = try #require(encoded as? [String: Any])

        #expect(dict["isDataset"] as? Bool == true)
        #expect(dict["datasetSampleSize"] as? Int == 25)
        #expect(dict["datasetSampleSizeText"] as? String == "25")
    }

    @Test func unmarkedRowEncodesAnEmptySampleSizeText() throws {
        let row = EditableSuiteRow(
            name: "notes.txt", url: "#", isTest: false, tier: "support", order: 1,
            dependsOn: [], points: 1, displayName: nil)
        let encoded = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(row))
        let dict = try #require(encoded as? [String: Any])

        #expect(dict["isDataset"] as? Bool == false)
        #expect(dict["datasetSampleSize"] == nil)
        #expect((dict["datasetSampleSizeText"] as? String)?.isEmpty == true)
    }

    // MARK: - One lookup behind both surfaces

    @Test func datasetSpecsByFileKeysEverySpecItsFile() throws {
        let props = try ManifestCodec.decoder.decode(
            TestProperties.self,
            from: Data(
                """
                {"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,
                 "makefile":null,
                 "datasets":[{"file":"a.csv","kind":"rowSample","sampleSize":5},
                             {"file":"b.csv","kind":"rowSample"}]}
                """.utf8))

        #expect(props.datasetSpecsByFile["a.csv"]?.sampleSize == 5)
        #expect(props.datasetSpecsByFile["b.csv"]?.sampleSize == nil)
        #expect(props.datasetSpecsByFile["absent.csv"] == nil)
    }
}
