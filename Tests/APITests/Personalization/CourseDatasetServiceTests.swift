// Tests/APITests/Personalization/CourseDatasetServiceTests.swift
//
// The course dataset library service (docs/datasets-course-library.md,
// slice 2): a dataset is created from its first version, versions are added
// with the dictionary prose carried by column name, publishing needs a
// provenance and a licence, usage is read from the course's manifests, a used
// dataset cannot be deleted, and the blob collector keeps dataset bytes.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class CourseDatasetServiceTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-course-datasets")
    }

    private var blobs: AssignmentVersionBlobStore {
        AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory)
    }

    private let firstCSV = "id,ward,systolic\n1,A,120\n2,B,131\n3,A,118\n"

    private func upload(
        _ csv: String, filename: String = "cases.csv", note: String? = nil
    )
        -> CourseDatasetService.Upload
    {
        CourseDatasetService.Upload(filename: filename, bytes: Data(csv.utf8), note: note)
    }

    private func newDataset(slug: String = "vitaldb-cases") -> CourseDatasetService.NewDataset {
        CourseDatasetService.NewDataset(
            name: "VitalDB cases", slug: slug, description: "Perioperative cases",
            provenance: nil, licence: nil)
    }

    private func course(_ code: String) async throws -> UUID {
        try await makeTestCourse(on: app, code: code, name: code).requireID()
    }

    private func create(
        courseID: UUID, slug: String = "vitaldb-cases", csv: String? = nil
    ) async throws -> APICourseDataset {
        try await CourseDatasetService.create(
            courseID: courseID, dataset: newDataset(slug: slug), upload: upload(csv ?? firstCSV), blobs: blobs,
            on: app.db
        ).dataset
    }

    // MARK: - Create

    @Test func createStoresVersionOneAndItsBytes() async throws {
        try await withApp(app) { app in
            let courseID = try await course("CDS1")
            let (dataset, version) = try await CourseDatasetService.create(
                courseID: courseID, dataset: newDataset(), upload: upload(firstCSV, note: "First extract"),
                blobs: blobs, on: app.db)

            #expect(dataset.slug == "vitaldb-cases")
            #expect(dataset.currentVersion == 1)
            #expect(!dataset.isPublished)
            #expect(version.version == 1)
            #expect(version.filename == "cases.csv")
            #expect(version.rowCount == 3)
            #expect(version.sizeBytes == firstCSV.utf8.count)
            #expect(version.sha256 == sha256HexDigest(firstCSV))
            #expect(version.note == "First extract")
            #expect(version.columns.map(\.name) == ["id", "ward", "systolic"])
            #expect(version.columns.map(\.valueType) == [.integer, .text, .integer])
            #expect(try CourseDatasetService.bytes(of: version, blobs: blobs) == Data(firstCSV.utf8))
        }
    }

    @Test(arguments: ["", "Vital", "-cases", "cases-", "a b", String(repeating: "a", count: 65)])
    func createRefusesAnInvalidSlug(slug: String) async throws {
        try await withApp(app) { app in
            let courseID = try await course("CDS2")
            await #expect(throws: CourseDatasetError.invalidSlug(slug)) {
                _ = try await self.create(courseID: courseID, slug: slug)
            }
            #expect(try await CourseDatasetService.list(courseID: courseID, on: app.db).isEmpty)
        }
    }

    @Test func aSlugIsUniquePerCourseOnly() async throws {
        try await withApp(app) { app in
            let first = try await course("CDS3A")
            let second = try await course("CDS3B")
            _ = try await create(courseID: first)
            await #expect(throws: CourseDatasetError.slugTaken("vitaldb-cases")) {
                _ = try await self.create(courseID: first)
            }
            _ = try await create(courseID: second)
            #expect(try await CourseDatasetService.list(courseID: second, on: app.db).count == 1)
        }
    }

    @Test(arguments: ["cases.json", "data/cases.csv", "../cases.csv", ".csv"])
    func createRefusesAFilenameThatIsNotABareCSV(filename: String) async throws {
        try await withApp(app) { _ in
            let courseID = try await course("CDS4")
            await #expect(throws: CourseDatasetError.invalidFilename(filename)) {
                _ = try await CourseDatasetService.create(
                    courseID: courseID, dataset: self.newDataset(),
                    upload: self.upload(self.firstCSV, filename: filename),
                    blobs: self.blobs, on: self.app.db)
            }
        }
    }

    @Test func createRefusesBytesThatAreNotUTF8() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("CDS5")
            let bytes = CourseDatasetService.Upload(filename: "cases.csv", bytes: Data([0xFF, 0xFE, 0x00]), note: nil)
            await #expect(throws: CourseDatasetError.notUTF8) {
                _ = try await CourseDatasetService.create(
                    courseID: courseID, dataset: self.newDataset(), upload: bytes, blobs: self.blobs, on: self.app.db)
            }
        }
    }

    @Test func createRefusesAFileOverTheLimit() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("CDS6")
            let header = "id\n"
            let size = CourseDatasetService.maxVersionBytes + 1
            let csv = header + String(repeating: "1", count: size - header.utf8.count)
            await #expect(
                throws: CourseDatasetError.tooLarge(sizeBytes: size, limitBytes: CourseDatasetService.maxVersionBytes)
            ) {
                _ = try await CourseDatasetService.create(
                    courseID: courseID, dataset: self.newDataset(), upload: self.upload(csv), blobs: self.blobs,
                    on: self.app.db)
            }
        }
    }

    @Test func createRefusesAFileWithoutAUsableHeader() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("CDS7")
            await #expect(throws: CourseDatasetError.notATable(.duplicateColumn("id"))) {
                _ = try await self.create(courseID: courseID, csv: "id,id\n1,2\n")
            }
        }
    }

    // MARK: - Versions

    @Test func addVersionCarriesTheDictionaryProseByColumnName() async throws {
        try await withApp(app) { app in
            let dataset = try await create(courseID: try await course("CDS8"))
            _ = try await CourseDatasetService.updateDictionary(
                dataset, version: 1,
                notes: [
                    .init(name: "ward", description: "Admitting ward", unit: nil),
                    .init(name: "systolic", description: "Systolic pressure", unit: "mmHg"),
                ],
                on: app.db)

            let added = try await CourseDatasetService.addVersion(
                to: dataset, upload: upload("id,ward,diastolic\n1,A,80\n", note: "Swap the pressure"),
                blobs: blobs, on: app.db)

            #expect(added.version.version == 2)
            #expect(added.droppedColumns == ["systolic"])
            #expect(added.version.columns.first { $0.name == "ward" }?.description == "Admitting ward")
            #expect(added.version.columns.first { $0.name == "diastolic" }?.description == nil)
            let reloaded = try #require(try await APICourseDataset.find(dataset.id, on: app.db))
            #expect(reloaded.currentVersion == 2)
            #expect(try await CourseDatasetService.versions(of: dataset, on: app.db).map(\.version) == [1, 2])
        }
    }

    @Test func addVersionRefusesTheBytesOfAnEarlierVersion() async throws {
        try await withApp(app) { app in
            let dataset = try await create(courseID: try await course("CDS9"))
            _ = try await CourseDatasetService.addVersion(
                to: dataset, upload: upload("id\n1\n"), blobs: blobs, on: app.db)
            await #expect(throws: CourseDatasetError.duplicateVersion(of: 1)) {
                _ = try await CourseDatasetService.addVersion(
                    to: dataset, upload: self.upload(self.firstCSV), blobs: self.blobs, on: self.app.db)
            }
        }
    }

    // MARK: - Dictionary

    @Test func updateDictionaryKeepsTheInferredTypes() async throws {
        try await withApp(app) { app in
            let dataset = try await create(courseID: try await course("CDS10"))
            let version = try await CourseDatasetService.updateDictionary(
                dataset, version: 1, notes: [.init(name: "systolic", description: "  ", unit: "mmHg")], on: app.db)
            let systolic = try #require(version.columns.first { $0.name == "systolic" })
            #expect(systolic.valueType == .integer)
            #expect(systolic.unit == "mmHg")
            #expect(systolic.description == nil)
        }
    }

    @Test func updateDictionaryRefusesAColumnTheFileLacks() async throws {
        try await withApp(app) { _ in
            let dataset = try await create(courseID: try await course("CDS11"))
            await #expect(throws: CourseDatasetError.dictionary("The file has no column named 'pulse'.")) {
                _ = try await CourseDatasetService.updateDictionary(
                    dataset, version: 1, notes: [.init(name: "pulse", description: "Heart rate", unit: nil)],
                    on: self.app.db)
            }
            await #expect(throws: CourseDatasetError.unknownVersion(7)) {
                _ = try await CourseDatasetService.updateDictionary(dataset, version: 7, notes: [], on: self.app.db)
            }
        }
    }

    // MARK: - Publishing

    @Test func publishingNeedsAProvenanceAndALicence() async throws {
        try await withApp(app) { app in
            let dataset = try await create(courseID: try await course("CDS12"))
            await #expect(throws: CourseDatasetError.missingGovernance) {
                try await CourseDatasetService.setPublished(dataset, true, on: self.app.db)
            }
            try await CourseDatasetService.updateMetadata(
                dataset, edit: .init(provenance: "VitalDB open dataset", licence: "CC BY 4.0"), on: app.db)
            try await CourseDatasetService.setPublished(dataset, true, on: app.db)
            #expect(try await APICourseDataset.find(dataset.id, on: app.db)?.isPublished == true)
        }
    }

    @Test func aPublishedDatasetKeepsItsLicence() async throws {
        try await withApp(app) { app in
            let dataset = try await create(courseID: try await course("CDS13"))
            try await CourseDatasetService.updateMetadata(
                dataset, edit: .init(provenance: "VitalDB open dataset", licence: "CC BY 4.0"), on: app.db)
            try await CourseDatasetService.setPublished(dataset, true, on: app.db)
            await #expect(throws: CourseDatasetError.governanceRequiredWhilePublished) {
                try await CourseDatasetService.updateMetadata(dataset, edit: .init(licence: ""), on: self.app.db)
            }
            #expect(try await APICourseDataset.find(dataset.id, on: app.db)?.licence == "CC BY 4.0")
        }
    }

    /// The dashboard and the upload page link to the Data page only when
    /// this is true.
    @Test func hasPublishedSeesOnlyPublishedDatasetsOfTheNamedSlugs() async throws {
        try await withApp(app) { app in
            let courseID = try await course("CDS30")
            let dataset = try await create(courseID: courseID)
            #expect(try await !CourseDatasetService.hasPublished(courseID: courseID, on: app.db))
            try await CourseDatasetService.updateMetadata(
                dataset, edit: .init(provenance: "VitalDB open dataset", licence: "CC BY 4.0"), on: app.db)
            try await CourseDatasetService.setPublished(dataset, true, on: app.db)
            #expect(try await CourseDatasetService.hasPublished(courseID: courseID, on: app.db))
            #expect(
                try await CourseDatasetService.hasPublished(courseID: courseID, slugs: ["vitaldb-cases"], on: app.db))
            #expect(try await !CourseDatasetService.hasPublished(courseID: courseID, slugs: ["other"], on: app.db))
            #expect(try await !CourseDatasetService.hasPublished(courseID: try await course("CDS31"), on: app.db))
        }
    }

    @Test func aRefusedMetadataEditLeavesTheModelAsItWas() async throws {
        try await withApp(app) { app in
            let dataset = try await create(courseID: try await course("CDS13B"))
            try await CourseDatasetService.updateMetadata(
                dataset, edit: .init(provenance: "VitalDB open dataset", licence: "CC BY 4.0"), on: app.db)
            try await CourseDatasetService.setPublished(dataset, true, on: app.db)
            await #expect(throws: CourseDatasetError.governanceRequiredWhilePublished) {
                try await CourseDatasetService.updateMetadata(
                    dataset, edit: .init(name: "Renamed", licence: " "), on: self.app.db)
            }
            #expect(dataset.name == "VitalDB cases")
            #expect(dataset.licence == "CC BY 4.0")
        }
    }

    @Test func aMetadataEditLeavesUnnamedFieldsAlone() async throws {
        try await withApp(app) { app in
            let dataset = try await create(courseID: try await course("CDS14"))
            try await CourseDatasetService.updateMetadata(dataset, edit: .init(name: "VitalDB extract"), on: app.db)
            let reloaded = try #require(try await APICourseDataset.find(dataset.id, on: app.db))
            #expect(reloaded.name == "VitalDB extract")
            #expect(reloaded.datasetDescription == "Perioperative cases")
            await #expect(throws: CourseDatasetError.invalidName) {
                try await CourseDatasetService.updateMetadata(dataset, edit: .init(name: " "), on: self.app.db)
            }
        }
    }

    // MARK: - Usage and delete

    private func attach(
        slug: String, version: Int, courseID: UUID, setupID: String, title: String?
    ) async throws {
        let manifest = """
            {"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null,\
            "datasets":[{"file":"cases.csv","sampleSize":2,"source":{"slug":"\(slug)","version":\(version)},\
            "transforms":[]}]}
            """
        try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: manifest, withNotebook: false, withZip: false)
        if let title {
            _ = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID, title: title)
        }
    }

    @Test func usageFindsEveryAssignmentAndDraftThatAttachesTheDataset() async throws {
        try await withApp(app) { app in
            let courseID = try await course("CDS15")
            let dataset = try await create(courseID: courseID)
            try await attach(slug: "vitaldb-cases", version: 1, courseID: courseID, setupID: "cds15_a", title: "Lab 2")
            try await attach(slug: "vitaldb-cases", version: 1, courseID: courseID, setupID: "cds15_b", title: nil)
            try await attach(slug: "nhanes-bp", version: 1, courseID: courseID, setupID: "cds15_c", title: "Lab 9")
            // The same slug in another course is another dataset.
            try await attach(
                slug: "vitaldb-cases", version: 1, courseID: try await course("CDS15X"), setupID: "cds15_d",
                title: "Elsewhere")

            let usage = try await CourseDatasetService.usage(of: dataset, on: app.db)
            #expect(usage.map(\.testSetupID) == ["cds15_a", "cds15_b"])
            #expect(usage[0].assignmentTitle == "Lab 2")
            #expect(usage[0].assignmentPublicID != nil)
            #expect(usage[1].assignmentPublicID == nil)
            #expect(usage.allSatisfy { $0.file == "cases.csv" && $0.version == 1 })
        }
    }

    @Test func aDatasetInUseCannotBeDeleted() async throws {
        try await withApp(app) { app in
            let courseID = try await course("CDS16")
            let dataset = try await create(courseID: courseID)
            try await attach(slug: "vitaldb-cases", version: 1, courseID: courseID, setupID: "cds16_a", title: "Lab 2")
            await #expect(throws: CourseDatasetError.inUse(by: ["'Lab 2'"])) {
                try await CourseDatasetService.delete(dataset, on: self.app.db)
            }
            #expect(try await APICourseDataset.find(dataset.id, on: app.db) != nil)
        }
    }

    @Test func deletingAnUnusedDatasetRemovesItsVersions() async throws {
        try await withApp(app) { app in
            let dataset = try await create(courseID: try await course("CDS17"))
            let datasetID = try dataset.requireID()
            try await CourseDatasetService.delete(dataset, on: app.db)
            #expect(try await APICourseDataset.find(datasetID, on: app.db) == nil)
            #expect(
                try await APICourseDatasetVersion.query(on: app.db).filter(\.$datasetID == datasetID).count() == 0)
        }
    }

    // MARK: - Blob collection

    @Test func theBlobCollectorKeepsDatasetVersionBytes() async throws {
        try await withApp(app) { app in
            let dataset = try await create(courseID: try await course("CDS18"))
            let version = try #require(try await CourseDatasetService.version(1, of: dataset, on: app.db))

            let referenced = try await AssignmentVersionStore.referencedBlobHashes(on: app.db)
            #expect(referenced.contains(version.sha256))
            // Far in the future, so the grace window cannot be what saves it.
            _ = blobs.collectGarbage(referenced: referenced, graceSeconds: 3600, now: Date().addingTimeInterval(86_400))
            #expect(blobs.exists(version.sha256))
        }
    }
}
