// Tests/APITests/MCP/DatasetWholeFileDeliveryTests.swift
//
// A sample that covers its whole file gives every student every row, so it is
// stored as no sample and delivered as one shared copy
// (docs/dataset-shared-delivery.md, "Whole-file samples"). Every door that
// saves a spec normalizes it, `set_dataset wholeFile:true` asks for the whole
// file directly, the MCP dataset tools report `datasetDelivery`, and a
// whole-file sample stored before the rule is reported as a warning.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

/// The tools read the setup zip with `unzip`, so the suite has a time limit.
@Suite(.serialized, .timeLimit(.minutes(5))) final class DatasetWholeFileDeliveryTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-ds-whole-file")
    }

    /// Three data rows in the library dataset, four in `notes.csv`.
    private static let pool = "id,ward\n1,A\n2,B\n3,A\n"

    private struct Fixture {
        let assignment: APIAssignment
        let subject: String
    }

    /// A course with the instructor `<code>_staff`, the library dataset
    /// `cases`, and an assignment whose zip holds a test and `notes.csv`.
    /// `datasets` is written into the manifest as it is, which is how a spec
    /// stored before the rule looks.
    private func fixture(code: String, datasets: [DatasetSpec] = []) async throws -> Fixture {
        let courseID = try await makeTestCourse(on: app, code: code).requireID()
        let subject = "\(code.lowercased())_staff"
        let staff = try await makeTestUser(on: app, username: subject, role: "instructor")
        try await makeTestEnrollment(on: app, userID: staff.requireID(), courseID: courseID)
        _ = try await CourseDatasetService.create(
            courseID: courseID, dataset: .init(name: "Cases", slug: "cases"),
            upload: .init(filename: "cases.csv", bytes: Data(Self.pool.utf8)),
            blobs: AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory), on: app.db)
        var props = TestProperties(testSuites: [TestSuiteEntry(tier: .pub, script: "test_a.sh")], language: .python)
        props.datasets = datasets
        let setupID = "wf_\(UUID().uuidString.prefix(8))"
        try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: try encodeManifest(props), withNotebook: false,
            withZip: false)
        try await writeZipFixture(
            at: app.testSetupsDirectory + setupID + ".zip",
            entries: [("test_a.sh", "exit 0\n"), ("notes.csv", "id,note\n1,a\n2,b\n3,c\n4,d\n")])
        let assignment = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
        return Fixture(assignment: assignment, subject: subject)
    }

    private func setup(of fx: Fixture) async throws -> APITestSetup {
        try #require(try await APITestSetup.find(fx.assignment.testSetupID, on: app.db))
    }

    private func storedSpec(_ fx: Fixture, _ file: String) async throws -> DatasetSpec? {
        try await setup(of: fx).decodedManifest()?.datasetSpecsByFile[file]
    }

    private func attach(_ fx: Fixture, sampleSize: Int?) async throws -> AttachDatasetTool.Output {
        try await AttachDatasetTool().execute(
            .init(
                assignmentPublicID: fx.assignment.publicID, slug: "cases", filename: nil, version: nil,
                sampleSize: sampleSize, stratumColumn: nil, scope: "assignment"),
            mcpContext(app, subject: fx.subject))
    }

    private func set(
        _ fx: Fixture, _ file: String, sampleSize: Int? = nil, stratumColumn: String? = nil, partCount: Int? = nil,
        wholeFile: Bool? = nil
    ) async throws -> SetDatasetTool.Output {
        try await SetDatasetTool().execute(
            .init(
                assignmentPublicID: fx.assignment.publicID, filename: file, sampleSize: sampleSize,
                stratumColumn: stratumColumn, remove: nil, transforms: nil, partCount: partCount,
                wholeFile: wholeFile),
            mcpContext(app, subject: fx.subject))
    }

    // MARK: - Normalized at save time

    /// The HLTH 230 case: a library attachment given a sample equal to its row
    /// count is stored with no sample, so it is `shared`, and keeps its source.
    @Test func aWholeFileSampleOnALibraryAttachmentIsStoredAsShared() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(code: "WFA1")
            _ = try await attach(fx, sampleSize: 2)
            let out = try await set(fx, "cases.csv", sampleSize: 3)

            let stored = try #require(try await storedSpec(fx, "cases.csv"))
            #expect(stored.sampleSize == nil)
            #expect(stored.deliveryMode == .shared)
            #expect(stored.source == DatasetSource(slug: "cases", version: 1))
            #expect(out.datasets.first?.datasetDelivery == "shared")
            #expect(out.notes.count == 1)
            #expect(out.notes.first?.contains("all 3 data rows") == true)
            #expect(out.warnings.isEmpty)
        }
    }

    /// A stratified whole-file sample loses its column with its sample:
    /// validation refuses a column on a spec with no sample.
    @Test func aStratifiedWholeFileSampleLosesItsColumn() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(code: "WFA2")
            _ = try await attach(fx, sampleSize: 2)
            _ = try await set(fx, "cases.csv", sampleSize: 10, stratumColumn: "ward")
            #expect(
                try await storedSpec(fx, "cases.csv")
                    == DatasetSpec(file: "cases.csv", source: DatasetSource(slug: "cases", version: 1)))
        }
    }

    /// A file not attached from the library keeps its spec: dropping it would
    /// drop the file from an upload-only submit page's downloads. The result
    /// warns instead.
    @Test func aWholeFileSampleOnAPlainFileIsKeptAndWarned() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(code: "WFA3")
            let out = try await set(fx, "notes.csv", sampleSize: 4)
            #expect(try await storedSpec(fx, "notes.csv")?.sampleSize == 4)
            #expect(out.datasets.first?.datasetDelivery == "perStudent")
            #expect(out.notes.isEmpty)
            #expect(out.warnings.count == 1)
            #expect(out.warnings.first?.contains("upload-only") == true)
        }
    }

    /// A sample below the row count is a real sample and is stored as sent.
    @Test func aSampleBelowTheRowCountIsKept() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(code: "WFA4")
            let out = try await set(fx, "notes.csv", sampleSize: 3)
            #expect(try await storedSpec(fx, "notes.csv")?.sampleSize == 3)
            #expect(out.datasets.first?.datasetDelivery == "perStudent")
            #expect(out.notes.isEmpty)
        }
    }

    /// The web `PUT /datasets` routes go through the same edit, which
    /// normalizes every library spec in the array they send.
    @Test func theWebEditNormalizesEveryLibrarySpecItSaves() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(code: "WFA5")
            _ = try await attach(fx, sampleSize: 2)
            let attached = try #require(try await storedSpec(fx, "cases.csv"))
            let normalized = try await applyDatasetsEdit(
                setup: try await setup(of: fx),
                change: .replaceAll([
                    DatasetSpec(file: "cases.csv", sampleSize: 3, source: attached.source, scope: attached.scope),
                    DatasetSpec(file: "notes.csv", sampleSize: 9),
                ]),
                on: app.db)
            #expect(normalized.map(\.file) == ["cases.csv"])
            #expect(try await storedSpec(fx, "cases.csv")?.deliveryMode == .shared)
            #expect(try await storedSpec(fx, "notes.csv")?.sampleSize == 9)
        }
    }

    /// A new attachment with a sample that covers the file is stored with
    /// none, and the result says so.
    @Test func attachingWithAWholeFileSampleStoresNone() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(code: "WFA6")
            let out = try await attach(fx, sampleSize: 3)
            #expect(out.dataset.sampleSize == nil)
            #expect(out.dataset.datasetDelivery == "shared")
            #expect(out.notes.count == 1)
            #expect(try await storedSpec(fx, "cases.csv")?.deliveryMode == .shared)
        }
    }

    // MARK: - wholeFile

    /// `wholeFile:true` turns a library partition into the whole file without
    /// a detach, which `remove` cannot do for an attached file.
    @Test func wholeFileEndsALibraryPartitionWithoutADetach() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(code: "WFB1")
            _ = try await attach(fx, sampleSize: nil)
            _ = try await set(fx, "cases.csv", partCount: 2)
            #expect(try await storedSpec(fx, "cases.csv")?.deliveryMode == .perPart)

            let out = try await set(fx, "cases.csv", wholeFile: true)
            let stored = try #require(try await storedSpec(fx, "cases.csv"))
            #expect(stored == DatasetSpec(file: "cases.csv", source: DatasetSource(slug: "cases", version: 1)))
            #expect(out.datasets.first?.datasetDelivery == "shared")
        }
    }

    /// On a file not attached from the library, `wholeFile:true` clears the
    /// mark, as `remove:true` would.
    @Test func wholeFileOnAPlainFileClearsTheMark() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(code: "WFB2")
            _ = try await set(fx, "notes.csv", sampleSize: 2)
            let out = try await set(fx, "notes.csv", wholeFile: true)
            #expect(try await storedSpec(fx, "notes.csv") == nil)
            #expect(out.notes.first?.contains("mark was cleared") == true)
        }
    }

    @Test func wholeFileRefusesAFieldThatSelectsRows() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(code: "WFB3")
            _ = try await set(fx, "notes.csv", sampleSize: 2)
            await #expect(throws: MCPToolError.self) {
                _ = try await self.set(fx, "notes.csv", sampleSize: 2, wholeFile: true)
            }
            await #expect(throws: MCPToolError.self) {
                _ = try await self.set(fx, "notes.csv", partCount: 2, wholeFile: true)
            }
            #expect(try await storedSpec(fx, "notes.csv")?.sampleSize == 2)
        }
    }

    // MARK: - Stored before the rule

    /// A whole-file sample stored before the rule is not migrated. An edit of
    /// another file reports it, and `check_assignment` finds it.
    @Test func aStoredWholeFileSampleIsReported() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(
                code: "WFC1", datasets: [DatasetSpec(file: "notes.csv", sampleSize: 4)])
            let setup = try await setup(of: fx)
            let found = await wholeFilePerStudentSamples(
                in: setup.decodedManifest()?.datasets ?? [], zipPath: setup.zipPath)
            #expect(
                found == [
                    WholeFilePerStudentSample(
                        file: "notes.csv", sampleSize: 4, dataRowCount: 4, isLibraryAttachment: false)
                ])

            let out = try await attach(fx, sampleSize: 2)
            #expect(out.warnings.count == 1)
            #expect(out.warnings.first?.contains("'notes.csv'") == true)

            let check = try await CheckAssignmentTool().execute(
                .init(assignmentPublicID: fx.assignment.publicID), mcpContext(app, subject: fx.subject))
            #expect(check.checksRun.contains(WholeFileSampleCheck.id))
            let finding = try #require(check.findings.first { $0.checkID == WholeFileSampleCheck.id })
            #expect(finding.severity == .warning)
            #expect(finding.location.reference == "notes.csv")
        }
    }

    /// An update to a smaller version keeps the carried sample, even where it
    /// now covers the file: the author chose it for another version, and a
    /// later, larger version should be sampled again.
    @Test func anUpdateToASmallerVersionKeepsTheSample() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(code: "WFC2")
            _ = try await attach(fx, sampleSize: 2)
            let dataset = try #require(
                try await CourseDatasetService.find(
                    courseID: try await setup(of: fx).courseID, slug: "cases", on: app.db))
            _ = try await CourseDatasetService.addVersion(
                to: dataset, upload: .init(filename: "cases.csv", bytes: Data("id,ward\n1,A\n2,B\n".utf8)),
                blobs: AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory), on: app.db)
            try await CourseDatasetService.updateAttachment(
                file: "cases.csv", in: try await setup(of: fx), to: nil,
                testSetupsDirectory: app.testSetupsDirectory, on: app.db)
            let stored = try #require(try await storedSpec(fx, "cases.csv"))
            #expect(stored.sampleSize == 2)
            #expect(stored.source?.version == 2)
        }
    }
}
