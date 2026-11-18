// Tests/APITests/Personalization/CourseDatasetFHIRLibraryTests.swift
//
// A FHIR NDJSON dataset in the course library (docs/fhir-datasets-plan.md §6,
// P2). The format is set at create and never changes: a version of another
// format is refused. A FHIR version stores its summary and its patient count
// and no columns. An attachment carries the dataset's format and is delivered
// whole, so a sample on it is refused. A promoted `.ndjson` support file
// becomes a FHIR dataset. The clone and the bundle carry the format, and a
// bundle import checks a FHIR version's bytes as FHIR. The staff download
// names the file by its format.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

/// The attach, the promote and the download run `zip` and `unzip`, so the
/// suite has a time limit.
@Suite(.serialized, .timeLimit(.minutes(5))) struct CourseDatasetFHIRLibraryTests {

    private static let feed = FHIRFeed.text
    private static let csv = "id,ward\n1,A\n2,B\n"

    private func blobs(_ app: Application) -> AssignmentVersionBlobStore {
        AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory)
    }

    private func createFeed(
        courseID: UUID, on app: Application, slug: String = "ed-feed"
    ) async throws -> (dataset: APICourseDataset, version: APICourseDatasetVersion) {
        try await CourseDatasetService.create(
            courseID: courseID, dataset: .init(name: "ED feed", slug: slug, format: .fhirNdjson),
            upload: .init(filename: "ed_feed.ndjson", bytes: Data(Self.feed.utf8)), blobs: blobs(app), on: app.db)
    }

    /// A setup in `courseID` whose zip holds `entries` and whose manifest
    /// holds `datasets`.
    private func makeSetup(
        courseID: UUID, entries: [(String, String)], datasets: String = "[]", on app: Application
    ) async throws -> APITestSetup {
        let setupID = "fh_\(UUID().uuidString.prefix(8))"
        try await writeZipFixture(
            at: app.testSetupsDirectory + setupID + ".zip", entries: [("test_a.sh", "exit 0\n")] + entries)
        let manifest = """
            {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test_a.sh"}],\
            "timeLimitSeconds":10,"makefile":null,"submissionMode":"uploadOnly","datasets":\(datasets)}
            """
        return try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: manifest, withNotebook: false, withZip: false)
    }

    // MARK: - Create and add a version

    @Test func aFHIRVersionStoresItsSummaryAndNoColumns() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let (dataset, version) = try await createFeed(courseID: courseID, on: app)

            #expect(dataset.format == .fhirNdjson)
            let stored = try #require(try await APICourseDataset.find(dataset.requireID(), on: app.db))
            #expect(stored.format == .fhirNdjson)
            let reread = try #require(try await CourseDatasetService.version(1, of: stored, on: app.db))
            #expect(reread.columns.isEmpty)
            #expect(reread.rowCount == 2)
            let summary = try #require(reread.summary)
            #expect(summary == (try FHIRNdjsonProfile.profile(Self.feed)))
            #expect(summary.patientCount == 2)
            #expect(version.filename == "ed_feed.ndjson")
        }
    }

    @Test func aCSVVersionStoresNoSummary() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let (dataset, version) = try await CourseDatasetService.create(
                courseID: courseID, dataset: .init(name: "Wards", slug: "wards"),
                upload: .init(filename: "wards.csv", bytes: Data(Self.csv.utf8)), blobs: blobs(app), on: app.db)
            #expect(dataset.format == .csv)
            #expect(version.summaryJSON == nil)
        }
    }

    @Test(
        "A FHIR upload is refused by name and by structure",
        arguments: [
            ("ed_feed.csv", FHIRFeed.text, CourseDatasetError.invalidFHIRFilename("ed_feed.csv")),
            (
                "ed_feed.ndjson", #"{"resourceType":"Patient","id":"p1"}"# + "\n" + #"{"id":"x"}"#,
                CourseDatasetError.notFHIR(.missingResourceType(line: 2))
            ),
            ("ed_feed.ndjson", "", CourseDatasetError.notFHIR(.empty)),
        ])
    func refusedUploads(filename: String, text: String, error: CourseDatasetError) async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            await #expect(throws: error) {
                try await CourseDatasetService.create(
                    courseID: courseID, dataset: .init(name: "ED feed", slug: "ed-feed", format: .fhirNdjson),
                    upload: .init(filename: filename, bytes: Data(text.utf8)), blobs: blobs(app), on: app.db)
            }
            #expect(try await CourseDatasetService.find(courseID: courseID, slug: "ed-feed", on: app.db) == nil)
        }
    }

    /// A dataset keeps the format it was created with.
    @Test func aVersionOfAnotherFormatIsRefused() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let (feed, _) = try await createFeed(courseID: courseID, on: app)
            await #expect(throws: CourseDatasetError.invalidFHIRFilename("wards.csv")) {
                try await CourseDatasetService.addVersion(
                    to: feed, upload: .init(filename: "wards.csv", bytes: Data(Self.csv.utf8)), blobs: blobs(app),
                    on: app.db)
            }
            let (wards, _) = try await CourseDatasetService.create(
                courseID: courseID, dataset: .init(name: "Wards", slug: "wards"),
                upload: .init(filename: "wards.csv", bytes: Data(Self.csv.utf8)), blobs: blobs(app), on: app.db)
            await #expect(throws: CourseDatasetError.invalidFilename("ed_feed.ndjson")) {
                try await CourseDatasetService.addVersion(
                    to: wards, upload: .init(filename: "ed_feed.ndjson", bytes: Data(Self.feed.utf8)),
                    blobs: blobs(app), on: app.db)
            }
        }
    }

    @Test func aNewFHIRVersionStoresItsOwnSummary() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let (feed, _) = try await createFeed(courseID: courseID, on: app)
            let longer = Self.feed + #"{"resourceType":"Patient","id":"p3"}"# + "\n"
            let added = try await CourseDatasetService.addVersion(
                to: feed, upload: .init(filename: "ed_feed.ndjson", bytes: Data(longer.utf8)), blobs: blobs(app),
                on: app.db)
            #expect(added.version.rowCount == 3)
            #expect(added.version.summary?.patientCount == 3)
            #expect(added.droppedColumns.isEmpty)
        }
    }

    // MARK: - Attach

    @Test func anAttachmentCarriesTheFormatAndPassesTheSourceCheck() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let (feed, _) = try await createFeed(courseID: courseID, on: app)
            let setup = try await makeSetup(courseID: courseID, entries: [], on: app)
            let spec = try await CourseDatasetService.attach(
                feed, to: setup, request: .init(scope: .assignment), testSetupsDirectory: app.testSetupsDirectory,
                on: app.db)
            #expect(spec.format == .fhirNdjson)
            #expect(spec.file == "ed_feed.ndjson")
            #expect(spec.deliveryMode == .shared)
            let stored = try #require(try await APITestSetup.find(setup.id, on: app.db))
            #expect(stored.decodedManifest()?.datasets == [spec])
            #expect(
                try await CourseDatasetService.sourceIssue(
                    for: spec, courseID: courseID, zipPath: stored.zipPath, on: app.db) == nil)
        }
    }

    @Test func aSampleOnAFHIRAttachmentIsRefused() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let (feed, _) = try await createFeed(courseID: courseID, on: app)
            let setup = try await makeSetup(courseID: courseID, entries: [], on: app)
            await #expect(throws: CourseDatasetError.self) {
                try await CourseDatasetService.attach(
                    feed, to: setup, request: .init(sampleSize: 1, scope: .assignment),
                    testSetupsDirectory: app.testSetupsDirectory, on: app.db)
            }
            let stored = try #require(try await APITestSetup.find(setup.id, on: app.db))
            #expect(stored.decodedManifest()?.datasets.isEmpty == true)
            #expect(await !listZipEntries(zipPath: stored.zipPath).contains("ed_feed.ndjson"))
        }
    }

    /// A spec whose format is not its library dataset's is a source the
    /// course cannot honour.
    @Test func aSpecOfAnotherFormatFailsTheSourceCheck() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let (feed, version) = try await createFeed(courseID: courseID, on: app)
            let setup = try await makeSetup(courseID: courseID, entries: [("ed_feed.ndjson", Self.feed)], on: app)
            let csvSpec = DatasetSpec(
                file: "ed_feed.ndjson", source: DatasetSource(slug: feed.slug, version: version.version))
            let issue = try #require(
                try await CourseDatasetService.sourceIssue(
                    for: csvSpec, courseID: courseID, zipPath: setup.zipPath, on: app.db))
            #expect(issue.contains("is marked CSV"))
            #expect(issue.contains("is FHIR NDJSON"))
        }
    }

    // MARK: - Promote

    @Test func aPromotedNDJSONFileBecomesAFHIRDataset() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setup = try await makeSetup(courseID: courseID, entries: [("ed_feed.ndjson", Self.feed)], on: app)
            let (dataset, spec) = try await CourseDatasetService.promote(
                file: "ed_feed.ndjson", from: setup, dataset: .init(name: "ED feed", slug: "ed-feed"),
                testSetupsDirectory: app.testSetupsDirectory, on: app.db)
            #expect(dataset.format == .fhirNdjson)
            #expect(spec.format == .fhirNdjson)
            #expect(spec.source == DatasetSource(slug: "ed-feed", version: 1))
            let version = try #require(try await CourseDatasetService.version(1, of: dataset, on: app.db))
            #expect(version.summary?.patientCount == 2)
        }
    }

    /// A FHIR file is delivered whole, so a sample it already has is refused
    /// before the dataset is created.
    @Test func aPromotedNDJSONFileWithASampleIsRefusedFirst() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setup = try await makeSetup(
                courseID: courseID, entries: [("ed_feed.ndjson", Self.feed)],
                datasets: #"[{"file":"ed_feed.ndjson","kind":"rowSample","sampleSize":1,"transforms":[]}]"#, on: app)
            await #expect(throws: CourseDatasetError.self) {
                try await CourseDatasetService.promote(
                    file: "ed_feed.ndjson", from: setup, dataset: .init(name: "ED feed", slug: "ed-feed"),
                    testSetupsDirectory: app.testSetupsDirectory, on: app.db)
            }
            #expect(try await CourseDatasetService.find(courseID: courseID, slug: "ed-feed", on: app.db) == nil)
        }
    }

    // MARK: - Clone and bundle

    @Test func aLibraryCopyKeepsTheFormatAndTheSummary() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let (_, version) = try await createFeed(courseID: courseID, on: app)
            let target = try await makeTestCourse(on: app, code: "FHIRCP", name: "Copy").requireID()
            try await CourseDatasetService.copyLibrary(from: courseID, to: target, on: app.db)

            let copy = try #require(try await CourseDatasetService.find(courseID: target, slug: "ed-feed", on: app.db))
            #expect(copy.format == .fhirNdjson)
            let copied = try #require(try await CourseDatasetService.version(1, of: copy, on: app.db))
            #expect(copied.summary == version.summary)
            #expect(copied.summary != nil)
        }
    }

    @Test func aBundleCarriesTheFormatAndAnImportRecomputesTheSummary() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let (_, version) = try await createFeed(courseID: courseID, on: app)
            let bundled = try await CourseDatasetService.bundledLibrary(courseID: courseID, on: app.db)
            #expect(bundled.map(\.format) == [.fhirNdjson])
            #expect(CourseBundleManifest.schemaVersion(carrying: bundled) == 3)

            let target = try await makeTestCourse(on: app, code: "FHIRBN", name: "Imported").requireID()
            let feed = Data(Self.feed.utf8)
            try await CourseDatasetService.importBundledLibrary(
                bundled, courseID: target, bytes: { _ in feed }, blobs: blobs(app), on: app.db)
            let imported = try #require(
                try await CourseDatasetService.find(courseID: target, slug: "ed-feed", on: app.db))
            #expect(imported.format == .fhirNdjson)
            let row = try #require(try await CourseDatasetService.version(1, of: imported, on: app.db))
            #expect(row.summary == version.summary)
            #expect(row.rowCount == 2)
        }
    }

    /// A bundle that claims a FHIR version whose bytes are not FHIR is
    /// refused before any row is written.
    @Test func aBundledFHIRVersionThatIsNotFHIRIsRefused() async throws {
        try await withAssignmentRoutesApp { app in
            let target = try await makeTestCourse(on: app, code: "FHIRBX", name: "Imported").requireID()
            let bytes = Data(Self.csv.utf8)
            let bundled = BundledDataset(
                slug: "ed-feed", name: "ED feed", description: nil, provenance: nil, licence: nil,
                isPublished: false, currentVersion: 1,
                versions: [
                    BundledDatasetVersion(
                        version: 1, filename: "ed_feed.ndjson", sha256: sha256HexDigest(bytes),
                        sizeBytes: bytes.count, rowCount: 2, columns: [], note: nil)
                ], format: .fhirNdjson)
            await #expect(throws: CourseDatasetError.self) {
                try await CourseDatasetService.importBundledLibrary(
                    [bundled], courseID: target, bytes: { _ in bytes }, blobs: blobs(app), on: app.db)
            }
            #expect(try await CourseDatasetService.find(courseID: target, slug: "ed-feed", on: app.db) == nil)
        }
    }

    // MARK: - Staff download

    @Test func theStaffDownloadIsNamedByTheFormat() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            _ = try await createFeed(courseID: courseID, on: app)
            try await app.asyncTest(
                .GET, "/instructor/datasets/download?slug=ed-feed&version=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string == Self.feed)
                    #expect(
                        res.headers.first(name: .contentDisposition) == "attachment; filename=\"ed-feed-v1.ndjson\"")
                    #expect(res.headers.first(name: .contentType) == "application/fhir+ndjson; charset=utf-8")
                })
        }
    }
}

/// Two patients, each with one Observation.
private enum FHIRFeed {
    static let text =
        [
            #"{"resourceType":"Patient","id":"p1"}"#,
            #"{"resourceType":"Patient","id":"p2"}"#,
            #"{"resourceType":"Observation","id":"o1","subject":{"reference":"Patient/p1"},"#
                + #""code":{"coding":[{"system":"http://loinc.org","code":"8310-5"}]}}"#,
            #"{"resourceType":"Observation","id":"o2","subject":{"reference":"Patient/p2"},"#
                + #""code":{"coding":[{"system":"http://loinc.org","code":"8310-5"}]}}"#,
        ].joined(separator: "\n") + "\n"
}
