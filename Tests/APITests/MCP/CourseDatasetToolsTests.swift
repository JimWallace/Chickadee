// Tests/APITests/MCP/CourseDatasetToolsTests.swift
//
// The MCP tools of the course dataset library
// (docs/datasets-course-library.md §4.7): what each one reads and writes, that
// an attach and a detach re-grade without closing the assignment, that the
// library fields are set only by `attach_dataset`, and the course gates.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

/// The attach and detach paths run `zip` and `unzip`, so the suite has a time
/// limit.
@Suite(.serialized, .timeLimit(.minutes(5))) final class CourseDatasetToolsTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-dataset-tools")
    }

    private static let pool = "id,ward,systolic\n1,A,120\n2,B,131\n3,A,118\n4,B,125\n5,A,140\n6,B,119\n"
    private static let newerPool = "id,ward,systolic\n1,A,120\n2,B,131\n3,A,118\n4,B,125\n"

    private struct Fixture {
        let courseID: UUID
        let assignment: APIAssignment
    }

    /// Course CDT1 with the instructor `cdt_staff`, the library dataset
    /// `ward-cases` (version 1, unpublished), and one open upload-mode
    /// assignment whose zip holds a test and the support file `notes.csv`.
    private func fixture(code: String = "CDT1", username: String = "cdt_staff") async throws -> Fixture {
        let courseID = try await makeTestCourse(on: app, code: code).requireID()
        let staff = try await makeTestUser(on: app, username: username, role: "instructor")
        try await makeTestEnrollment(on: app, userID: staff.requireID(), courseID: courseID)
        _ = try await CourseDatasetService.create(
            courseID: courseID, dataset: .init(name: "Ward cases", slug: "ward-cases"),
            upload: .init(filename: "cases.csv", bytes: Data(Self.pool.utf8)),
            blobs: AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory), on: app.db)

        let setupID = "cdt_\(UUID().uuidString.prefix(8))"
        let manifest = """
            {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test_a.sh"}],\
            "timeLimitSeconds":10,"makefile":null,"submissionMode":"uploadOnly"}
            """
        try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: manifest, withNotebook: false, withZip: false)
        try await writeZipFixture(
            at: app.testSetupsDirectory + setupID + ".zip",
            entries: [("test_a.sh", "exit 0\n"), ("notes.csv", "id,note\n1,a\n2,b\n")])
        let assignment = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
        return Fixture(courseID: courseID, assignment: assignment)
    }

    private func courseID(_ code: String) async throws -> UUID {
        try #require(try await APICourse.query(on: app.db).filter(\.$code == code).first()).requireID()
    }

    private func context(_ username: String = "cdt_staff") -> ToolContext {
        ToolContext(request: makeTestRequest(on: app), subject: username, grantedScopes: [.read, .write])
    }

    private func fetching(_ csv: String) -> DatasetSourceFetch {
        { _, _ in Data(csv.utf8) }
    }

    private func setup(of fx: Fixture) async throws -> APITestSetup {
        try #require(try await APITestSetup.find(fx.assignment.testSetupID, on: app.db))
    }

    private func attach(
        _ fx: Fixture, filename: String? = nil, version: Int? = nil, sampleSize: Int? = nil, scope: String? = nil,
        as username: String = "cdt_staff"
    ) async throws -> AttachDatasetTool.Output {
        try await AttachDatasetTool().execute(
            .init(
                assignmentPublicID: fx.assignment.publicID, slug: "ward-cases", filename: filename,
                version: version, sampleSize: sampleSize, stratumColumn: nil, scope: scope),
            context(username))
    }

    private func addVersion(_ csv: String) async throws -> AddDatasetVersionTool.Output {
        try await AddDatasetVersionTool(fetch: fetching(csv)).execute(
            .init(
                courseCode: "CDT1", slug: "ward-cases", sourceUrl: "https://example.org/v2.csv", filename: nil,
                note: "Fewer rows"),
            context())
    }

    // MARK: - Reading

    @Test func listDatasetsReportsVersionsDictionaryAndUsage() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            _ = try await attach(fx, sampleSize: 3)
            let out = try await ListDatasetsTool().execute(.init(courseCode: "CDT1"), context())
            let dataset = try #require(out.datasets.first)
            #expect(out.datasets.count == 1)
            #expect(dataset.slug == "ward-cases")
            #expect(!dataset.isPublished)
            #expect(dataset.versions.map(\.rowCount) == [6])
            #expect(dataset.columns.map(\.name) == ["id", "ward", "systolic"])
            #expect(dataset.usage.map(\.assignmentPublicID) == [fx.assignment.publicID])
            #expect(dataset.usage.first?.isBehind == false)
        }
    }

    @Test func getDatasetReturnsTheHeaderAndTheFirstRows() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            let out = try await GetDatasetTool().execute(
                .init(courseCode: "CDT1", slug: "ward-cases", version: nil, maxRows: 2), context())
            #expect(out.version == 1)
            #expect(out.rows == "id,ward,systolic\n1,A,120\n2,B,131\n")
            #expect(out.rowCount == 6)
            #expect(out.truncated)
            await #expect(throws: MCPToolError.self) {
                _ = try await GetDatasetTool().execute(
                    .init(courseCode: "CDT1", slug: "no-such", version: nil, maxRows: nil), self.context())
            }
        }
    }

    // MARK: - The library

    @Test func createDatasetFromAURLStartsUnpublished() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            let out = try await CreateDatasetTool(fetch: fetching(Self.pool)).execute(
                .init(
                    courseCode: "CDT1", name: "Blood pressure", slug: nil, description: nil, provenance: nil,
                    licence: nil, sourceUrl: "https://example.org/data/bp.csv", note: nil, assignmentPublicID: nil,
                    filename: nil),
                context())
            #expect(out.dataset.slug == "blood-pressure")
            #expect(!out.dataset.isPublished)
            #expect(out.dataset.versions.map(\.filename) == ["bp.csv"])
        }
    }

    @Test func createDatasetNeedsExactlyOneSource() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            for (url, publicID) in [(nil, nil), ("https://example.org/a.csv", fx.assignment.publicID)] {
                await #expect(throws: MCPToolError.self) {
                    _ = try await CreateDatasetTool(fetch: self.fetching(Self.pool)).execute(
                        .init(
                            courseCode: "CDT1", name: "Two", slug: nil, description: nil, provenance: nil,
                            licence: nil, sourceUrl: url, note: nil, assignmentPublicID: publicID,
                            filename: "notes.csv"),
                        self.context())
                }
            }
        }
    }

    /// The default fetch refuses a loopback host before it connects.
    @Test func createDatasetFetchesUnderTheSSRFGuard() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateDatasetTool().execute(
                    .init(
                        courseCode: "CDT1", name: "Local", slug: nil, description: nil, provenance: nil,
                        licence: nil, sourceUrl: "https://127.0.0.1/secret.csv", note: nil,
                        assignmentPublicID: nil, filename: nil),
                    self.context())
            }
        }
    }

    @Test func createDatasetPromotesASupportFileWithoutChangingIt() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let out = try await CreateDatasetTool().execute(
                .init(
                    courseCode: "CDT1", name: "Notes", slug: nil, description: nil, provenance: nil,
                    licence: nil, sourceUrl: nil, note: nil, assignmentPublicID: fx.assignment.publicID,
                    filename: "notes.csv"),
                context())
            #expect(out.dataset.usage.map(\.file) == ["notes.csv"])
            let spec = try #require(try await setup(of: fx).decodedManifest()?.datasetSpecsByFile["notes.csv"])
            #expect(spec.source == DatasetSource(slug: "notes", version: 1))
            #expect(spec.scope == .assignment)
            let reloaded = try #require(try await APIAssignment.find(fx.assignment.id, on: app.db))
            #expect(reloaded.visibility == .open)
        }
    }

    @Test func updateDatasetPublishesOnlyWithAProvenanceAndALicence() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            func update(provenance: String?, licence: String?) async throws -> UpdateDatasetTool.Output {
                try await UpdateDatasetTool().execute(
                    .init(
                        courseCode: "CDT1", slug: "ward-cases", name: nil, description: nil, provenance: provenance,
                        licence: licence, isPublished: true, columns: nil),
                    self.context())
            }
            await #expect(throws: MCPToolError.self) { _ = try await update(provenance: nil, licence: nil) }
            let out = try await update(provenance: "Hospital extract", licence: "Course use only")
            #expect(out.dataset.isPublished)
            #expect(out.dataset.licence == "Course use only")
        }
    }

    @Test func updateDatasetChangesOnlyTheColumnsItNames() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            func describe(_ columns: [UpdateDatasetTool.ColumnInput]) async throws -> UpdateDatasetTool.Output {
                try await UpdateDatasetTool().execute(
                    .init(
                        courseCode: "CDT1", slug: "ward-cases", name: nil, description: nil, provenance: nil,
                        licence: nil, isPublished: nil, columns: columns),
                    self.context())
            }
            _ = try await describe([.init(name: "ward", description: "Hospital ward", unit: nil)])
            let out = try await describe([.init(name: "systolic", description: nil, unit: "mmHg")])
            let byName = Dictionary(uniqueKeysWithValues: out.dataset.columns.map { ($0.name, $0) })
            #expect(byName["ward"]?.description == "Hospital ward")
            #expect(byName["systolic"]?.unit == "mmHg")
            await #expect(throws: MCPToolError.self) {
                _ = try await describe([.init(name: "pulse", description: "Not in the file", unit: nil)])
            }
        }
    }

    @Test func aNewVersionLeavesAttachmentsBehindUntilTheyMove() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            _ = try await attach(fx)
            let added = try await addVersion(Self.newerPool)
            #expect(added.version == 2)
            #expect(added.dataset.usage.first?.isBehind == true)
            let spec = try #require(try await setup(of: fx).decodedManifest()?.datasetSpecsByFile["cases.csv"])
            #expect(spec.source?.version == 1)

            let moved = try await attach(fx)
            #expect(moved.action == "updated")
            #expect(moved.dataset.version == 2)
            #expect(try await attach(fx).action == "unchanged")
        }
    }

    @Test func aRefusedUpdateLeavesTheDatasetAsItWas() async throws {
        try await withApp(app) { app in
            _ = try await fixture()
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateDatasetTool().execute(
                    .init(
                        courseCode: "CDT1", slug: "ward-cases", name: "Renamed", description: nil,
                        provenance: nil, licence: nil, isPublished: true, columns: nil),
                    self.context())
            }
            let stored = try #require(
                try await CourseDatasetService.find(courseID: try await self.courseID("CDT1"), slug: "ward-cases", on: app.db))
            #expect(stored.name == "Ward cases")
        }
    }

    /// One call may unpublish a dataset and clear its licence, because the
    /// unpublish runs first.
    @Test func oneUpdateCanUnpublishAndClearTheLicence() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            func update(licence: String, publish: Bool) async throws -> UpdateDatasetTool.Output {
                try await UpdateDatasetTool().execute(
                    .init(
                        courseCode: "CDT1", slug: "ward-cases", name: nil, description: nil,
                        provenance: "Hospital extract", licence: licence, isPublished: publish, columns: nil),
                    self.context())
            }
            _ = try await update(licence: "Course use only", publish: true)
            let out = try await update(licence: "", publish: false)
            #expect(!out.dataset.isPublished)
            #expect(out.dataset.licence == nil)
        }
    }

    @Test func createDatasetRefusesToPromoteAFileOfAnotherCourse() async throws {
        try await withApp(app) { app in
            let fx = try await fixture()
            let other = try await makeTestCourse(on: app, code: "CDT3").requireID()
            let staff = try #require(try await APIUser.query(on: app.db).filter(\.$username == "cdt_staff").first())
            try await makeTestEnrollment(on: app, userID: staff.requireID(), courseID: other)
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateDatasetTool().execute(
                    .init(
                        courseCode: "CDT3", name: "Notes", slug: nil, description: nil, provenance: nil,
                        licence: nil, sourceUrl: nil, note: nil, assignmentPublicID: fx.assignment.publicID,
                        filename: "notes.csv"),
                    self.context())
            }
        }
    }

    // MARK: - Attachments

    @Test func attachCopiesTheFileWithCourseScopeAndDoesNotClose() async throws {
        try await withApp(app) { app in
            let fx = try await fixture()
            let out = try await attach(fx, sampleSize: 3)
            #expect(out.action == "attached")
            #expect(out.dataset.file == "cases.csv")
            #expect(out.dataset.scope == "course")
            #expect(out.dataset.sampleSize == 3)
            let setup = try await setup(of: fx)
            #expect(await extractZipEntry(zipPath: setup.zipPath, entryName: "cases.csv") == Data(Self.pool.utf8))
            let reloaded = try #require(try await APIAssignment.find(fx.assignment.id, on: app.db))
            #expect(reloaded.visibility == .open)

            let files = try await GetSupportFilesTool().execute(
                .init(assignmentPublicID: fx.assignment.publicID, filename: nil, maxBytes: nil), context())
            let entry = try #require(files.files?.first { $0.filename == "cases.csv" })
            #expect(entry.datasetSource == DatasetSource(slug: "ward-cases", version: 1))
            #expect(entry.datasetScope == "course")
            let details = try await GetAssignmentTool().execute(
                .init(assignmentPublicID: fx.assignment.publicID), context())
            #expect(details.datasets.map(\.slug) == ["ward-cases"])
        }
    }

    @Test func attachChangesTheScopeOfAnAttachedFileButNotItsSample() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            _ = try await attach(fx, sampleSize: 3)
            let out = try await attach(fx, scope: "assignment")
            #expect(out.action == "updated")
            #expect(out.dataset.scope == "assignment")
            #expect(out.dataset.sampleSize == 3)
            await #expect(throws: MCPToolError.self) { _ = try await self.attach(fx, sampleSize: 2) }
            await #expect(throws: MCPToolError.self) { _ = try await self.attach(fx, scope: "class") }
        }
    }

    @Test func attachRefusesANameThatAnotherFileHas() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            await #expect(throws: MCPToolError.self) { _ = try await self.attach(fx, filename: "notes.csv") }
        }
    }

    /// A second filename makes a second attachment. With two, a call that
    /// names no file is refused, and one that names a file changes only it.
    @Test func aDatasetAttachedTwiceNeedsAFilename() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            _ = try await attach(fx)
            #expect(try await attach(fx, filename: "second.csv").action == "attached")
            await #expect(throws: MCPToolError.self) { _ = try await self.attach(fx, scope: "assignment") }
            let out = try await attach(fx, filename: "second.csv", scope: "assignment")
            #expect(out.action == "updated")
            let specs = try #require(try await setup(of: fx).decodedManifest()?.datasetSpecsByFile)
            #expect(specs["cases.csv"]?.scope == .course)
            #expect(specs["second.csv"]?.scope == .assignment)
        }
    }

    @Test func anUnchangedAttachRegradesNothing() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            _ = try await attach(fx, scope: "course")
            let out = try await attach(fx, version: 1, scope: "course")
            #expect(out.action == "unchanged")
            #expect(out.submissionsRequeued == 0)
        }
    }

    @Test func detachKeepsTheFileAndItsSampleUnlessAskedToRemoveIt() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            _ = try await attach(fx, sampleSize: 3)
            func detach(removeFile: Bool?) async throws -> DetachDatasetTool.Output {
                try await DetachDatasetTool().execute(
                    .init(assignmentPublicID: fx.assignment.publicID, filename: "cases.csv", removeFile: removeFile),
                    self.context())
            }
            _ = try await detach(removeFile: nil)
            let kept = try #require(try await setup(of: fx).decodedManifest()?.datasetSpecsByFile["cases.csv"])
            #expect(kept.source == nil)
            #expect(kept.sampleSize == 3)
            #expect(kept.scope == .assignment)
            // Detached now, so a second detach is refused.
            await #expect(throws: MCPToolError.self) { _ = try await detach(removeFile: true) }

            _ = try await attach(fx, filename: "again.csv")
            _ = try await DetachDatasetTool().execute(
                .init(assignmentPublicID: fx.assignment.publicID, filename: "again.csv", removeFile: true),
                context())
            let setup = try await setup(of: fx)
            #expect(await extractZipEntry(zipPath: setup.zipPath, entryName: "again.csv") == nil)
        }
    }

    // MARK: - Gates

    @Test func aStudentCannotWriteToTheLibrary() async throws {
        try await withApp(app) { app in
            let fx = try await fixture()
            let student = try await makeTestUser(on: app, username: "cdt_student")
            try await makeTestEnrollment(on: app, userID: student.requireID(), courseID: fx.courseID)
            await #expect(throws: MCPToolError.self) { _ = try await self.attach(fx, as: "cdt_student") }
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateDatasetTool().execute(
                    .init(
                        courseCode: "CDT1", slug: "ward-cases", name: "Renamed", description: nil, provenance: nil,
                        licence: nil, isPublished: nil, columns: nil),
                    self.context("cdt_student"))
            }
        }
    }

    /// The instructor of another course can neither read this library nor
    /// attach from it.
    @Test func anotherCoursesStaffReachesNeitherTheLibraryNorTheAssignment() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            _ = try await fixture(code: "CDT2", username: "cdt_other")
            await #expect(throws: MCPToolError.self) {
                _ = try await ListDatasetsTool().execute(.init(courseCode: "CDT1"), self.context("cdt_other"))
            }
            await #expect(throws: MCPToolError.self) { _ = try await self.attach(fx, as: "cdt_other") }
        }
    }
}
