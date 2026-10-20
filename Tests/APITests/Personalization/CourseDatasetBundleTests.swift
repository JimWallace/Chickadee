// Tests/APITests/Personalization/CourseDatasetBundleTests.swift
//
// The course dataset library in a course bundle
// (docs/datasets-course-library.md §4.8). A bundle carries the library as
// schemaVersion 2, with each version's bytes at `datasets/<sha256>`; a course
// without a dataset still exports version 1. An import creates the library
// before the setups, so an imported assignment keeps its library source, and
// it refuses a dataset file that is not the one the bundle names.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

/// The export and import run `zip` and `unzip`, so the suite has a time
/// limit.
@Suite(.serialized, .timeLimit(.minutes(5))) final class CourseDatasetBundleTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-ds-bundle")
    }

    private let pool = "id,ward,systolic\n1,A,120\n2,B,131\n3,A,118\n4,B,125\n5,A,140\n"
    private let newerPool = "id,ward,systolic\n1,A,121\n2,B,131\n3,A,118\n"

    /// A course with a published dataset of two versions, and an assignment
    /// that attaches version 1 with a course-scoped sample.
    private func makeCourse(code: String, withDataset: Bool = true) async throws -> APICourse {
        let setupID = "bd_\(UUID().uuidString.prefix(8))"
        try await writeZipFixture(at: app.testSetupsDirectory + setupID + ".zip", entries: [("test_a.sh", "exit 0\n")])
        let manifest = """
            {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test_a.sh"}],\
            "timeLimitSeconds":10,"makefile":null,"submissionMode":"uploadOnly"}
            """
        let scenario = try await TestScenario.make(
            on: app, code: code, setupID: setupID, manifest: manifest, withNotebook: false, withZip: false,
            title: "Lab 2")
        let course = scenario.course
        let courseID = scenario.courseID
        let setup = scenario.setup
        guard withDataset else { return course }

        let blobs = AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory)
        let dataset = try await CourseDatasetService.create(
            courseID: courseID,
            dataset: .init(
                name: "Ward cases", slug: "ward-cases", description: "Admissions by ward",
                provenance: "Hospital extract", licence: "Course use only"),
            upload: .init(filename: "cases.csv", bytes: Data(pool.utf8), note: "First cut"), blobs: blobs,
            on: app.db
        ).dataset
        try await CourseDatasetService.setPublished(dataset, true, on: app.db)
        _ = try await CourseDatasetService.addVersion(
            to: dataset, upload: .init(filename: "cases.csv", bytes: Data(newerPool.utf8)), blobs: blobs, on: app.db)
        try await CourseDatasetService.attach(
            dataset, to: setup, request: .init(version: 1, sampleSize: 3, scope: .course),
            testSetupsDirectory: app.testSetupsDirectory, on: app.db)
        return course
    }

    private func export(_ course: APICourse, cookie: String) async throws -> Data {
        var zip = Data()
        try await app.asyncTest(
            .GET, "/admin/courses/\(try course.requireID().uuidString)/export",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                #expect(res.status == .ok)
                zip = Data(res.body.readableBytesView)
            })
        return zip
    }

    /// Unzips `zip` into a new directory, which the caller removes.
    private func extract(_ zip: Data) async throws -> URL {
        let zipPath = FileManager.default.temporaryDirectory.appendingPathComponent("bd-\(UUID().uuidString).zip").path
        defer { try? FileManager.default.removeItem(atPath: zipPath) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bd-extract-\(UUID().uuidString)", isDirectory: true)
        try zip.write(to: URL(fileURLWithPath: zipPath))
        try await extractZipArchive(zipPath: zipPath, into: directory)
        return directory
    }

    private func zip(_ directory: URL) async throws -> Data {
        let outPath = FileManager.default.temporaryDirectory.appendingPathComponent("bd-out-\(UUID().uuidString).zip")
            .path
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        try await createZipArchive(sourceDir: directory, outputPath: outPath)
        return try Data(contentsOf: URL(fileURLWithPath: outPath))
    }

    private func manifest(in directory: URL) throws -> CourseBundleManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            CourseBundleManifest.self, from: Data(contentsOf: directory.appendingPathComponent("bundle.json")))
    }

    private func postImport(_ zip: Data, cookie: String) async throws -> (status: HTTPStatus, body: String) {
        let (csrf, sessionCookie) = try await csrfFields(for: "/admin", cookie: cookie, on: app)
        let boundary = "bd-boundary-\(UUID().uuidString)"
        var body = ByteBuffer()
        body.writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n\(csrf)\r\n")
        body.writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"bundle.zip\"\r\n")
        body.writeString("Content-Type: application/zip\r\n\r\n")
        body.writeBytes(zip)
        body.writeString("\r\n--\(boundary)--\r\n")
        var result: (HTTPStatus, String) = (.internalServerError, "")
        try await app.asyncTest(
            .POST, "/admin/courses/import",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = body
            },
            afterResponse: { res in result = (res.status, res.body.string) })
        return result
    }

    /// Archives `course`, so an import of its bundle can take the code.
    private func archive(_ course: APICourse) async throws {
        course.isArchived = true
        try await course.save(on: app.db)
    }

    private func importedCourse(code: String) async throws -> APICourse {
        try #require(
            try await APICourse.query(on: app.db).filter(\.$code == code).filter(\.$isArchived == false).first())
    }

    // MARK: - Export

    @Test func aBundleCarriesTheLibraryAsVersionTwo() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("bd_admin", on: app)
            let course = try await makeCourse(code: "BDX1")
            let directory = try await extract(try await export(course, cookie: cookie))
            defer { try? FileManager.default.removeItem(at: directory) }

            let manifest = try manifest(in: directory)
            #expect(manifest.schemaVersion == CourseBundleManifest.datasetsSchemaVersion)
            let dataset = try #require(manifest.datasets?.first)
            #expect(dataset.slug == "ward-cases")
            #expect(dataset.provenance == "Hospital extract")
            #expect(dataset.isPublished)
            #expect(dataset.versions.map(\.version) == [1, 2])
            #expect(dataset.versions.map(\.note) == ["First cut", nil])
            let first = try #require(dataset.versions.first)
            #expect(try Data(contentsOf: directory.appendingPathComponent(first.bundleFilename)) == Data(pool.utf8))
        }
    }

    /// A bundle without a dataset stays version 1, which a server that
    /// knows only version 1 can read.
    @Test func aCourseWithoutADatasetExportsVersionOne() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("bd_admin", on: app)
            let course = try await makeCourse(code: "BDX2", withDataset: false)
            let directory = try await extract(try await export(course, cookie: cookie))
            defer { try? FileManager.default.removeItem(at: directory) }
            let manifest = try manifest(in: directory)
            #expect(manifest.schemaVersion == 1)
            #expect(manifest.datasets == nil)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("datasets").path))
        }
    }

    // MARK: - Import

    @Test func anImportedAssignmentKeepsItsLibrarySource() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("bd_admin", on: app)
            let course = try await makeCourse(code: "BDI1")
            let bundle = try await export(course, cookie: cookie)
            try await archive(course)

            let (status, body) = try await postImport(bundle, cookie: cookie)
            #expect(status == .ok, "\(body.prefix(300))")
            #expect(body.contains("Datasets"))
            let imported = try await importedCourse(code: "BDI1")
            let importedID = try imported.requireID()
            let dataset = try #require(
                try await CourseDatasetService.find(courseID: importedID, slug: "ward-cases", on: app.db))
            #expect(dataset.isPublished)
            #expect(dataset.currentVersion == 2)
            #expect(try await CourseDatasetService.versions(of: dataset, on: app.db).map(\.rowCount) == [5, 3])

            let setup = try #require(
                try await APITestSetup.query(on: app.db).filter(\.$courseID == importedID).first())
            let spec = try #require(setup.decodedManifest()?.datasetSpecsByFile["cases.csv"])
            #expect(spec.source == DatasetSource(slug: "ward-cases", version: 1))
            #expect(spec.scope == .course)
        }
    }

    @Test func anImportRefusesADatasetFileThatIsNotTheOneNamed() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("bd_admin", on: app)
            let course = try await makeCourse(code: "BDI2")
            let directory = try await extract(try await export(course, cookie: cookie))
            defer { try? FileManager.default.removeItem(at: directory) }
            try await archive(course)

            let version = try #require(try manifest(in: directory).datasets?.first?.versions.first)
            try Data("id,ward,systolic\n9,Z,999\n".utf8).write(
                to: directory.appendingPathComponent(version.bundleFilename))
            let (status, body) = try await postImport(try await zip(directory), cookie: cookie)
            #expect(status == .badRequest)
            #expect(body.contains("not the file the bundle names"))
            #expect(try await APICourse.query(on: app.db).filter(\.$code == "BDI2").count() == 1)
        }
    }

    /// A malformed library is refused by name before any row is written,
    /// not by a unique index.
    @Test func aBundledLibraryWithARepeatedSlugOrVersionIsRefused() async throws {
        try await withApp(app) { app in
            let courseID = try await makeTestCourse(on: app, code: "BDI4").requireID()
            let bytes = Data(pool.utf8)
            let version = BundledDatasetVersion(
                version: 1, filename: "cases.csv", sha256: sha256HexDigest(bytes), sizeBytes: bytes.count,
                rowCount: 5, columns: [], note: nil)
            func dataset(_ versions: [BundledDatasetVersion]) -> BundledDataset {
                BundledDataset(
                    slug: "ward-cases", name: "Ward cases", description: nil, provenance: nil, licence: nil,
                    isPublished: false, currentVersion: 1, versions: versions)
            }
            let blobs = AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory)
            for (library, error) in [
                ([dataset([version]), dataset([version])], CourseDatasetError.slugTaken("ward-cases")),
                ([dataset([version, version])], CourseDatasetError.bundledVersionNumbers("ward-cases")),
            ] {
                await #expect(throws: error) {
                    try await CourseDatasetService.importBundledLibrary(
                        library, courseID: courseID, bytes: { _ in bytes }, blobs: blobs, on: app.db)
                }
            }
            #expect(try await CourseDatasetService.list(courseID: courseID, on: app.db).isEmpty)
        }
    }

    @Test func anImportRefusesAMissingDatasetFile() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("bd_admin", on: app)
            let course = try await makeCourse(code: "BDI3")
            let directory = try await extract(try await export(course, cookie: cookie))
            defer { try? FileManager.default.removeItem(at: directory) }
            try await archive(course)

            try FileManager.default.removeItem(at: directory.appendingPathComponent("datasets"))
            let (status, body) = try await postImport(try await zip(directory), cookie: cookie)
            #expect(status == .badRequest)
            #expect(body.contains("invalid dataset file"))
        }
    }
}
