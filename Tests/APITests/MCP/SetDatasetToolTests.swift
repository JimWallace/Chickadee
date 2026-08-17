// Tests for SetDatasetTool (mark a bundled support file as a per-student
// dataset, or clear the mark), backed by a real test database. Mirrors the
// validation of the web PUT /instructor/:id/datasets endpoint: bare filename,
// must be a bundled support file (not a graded script or notebook), positive
// sampleSize — and, like that endpoint, never closes the assignment.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct SetDatasetToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.read, .write]
        )
    }

    private let manifest = """
        {"schemaVersion":1,"testSuites":[\
        {"tier":"public","script":"test_a.sh","points":1}\
        ],"timeLimitSeconds":10}
        """

    private func fixture(on app: Application) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "HLTH230", name: "Health Informatics")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_ds", courseID: courseID, manifest: manifest)
        try writeZip(
            at: app.testSetupsDirectory + "setup_ds.zip",
            entries: [
                ("test_a.sh", "exit 0\n"),
                ("assignment.ipynb", "{}"),
                ("solution.ipynb", "{}"),
                ("cases.csv", "caseid,age\n1,20\n2,30\n3,40\n"),
            ])
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_ds", courseID: courseID, title: "A4")
    }

    private func writeZip(at zipPath: String, entries: [(String, String)]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, content) in entries {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.data(using: .utf8)?.write(to: url)
        }
        try? FileManager.default.removeItem(atPath: zipPath)
        try writeZipFixture(of: root, to: zipPath)
    }

    private func run(
        _ app: Application, publicID: String, filename: String,
        sampleSize: Int? = nil, stratumColumn: String? = nil, remove: Bool? = nil,
        transforms: [SetDatasetTool.TransformInput]? = nil
    ) async throws -> SetDatasetTool.Output {
        try await SetDatasetTool().execute(
            SetDatasetTool.Input(
                assignmentPublicID: publicID, filename: filename,
                sampleSize: sampleSize, stratumColumn: stratumColumn, remove: remove,
                transforms: transforms),
            context(app))
    }

    // MARK: - Marking

    @Test func marksSupportFileAsDataset_withoutClosing() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            #expect(assignment.visibility == .open)

            let out = try await run(
                app, publicID: assignment.publicID, filename: "cases.csv", sampleSize: 2)
            #expect(out.datasets.map(\.file) == ["cases.csv"])
            #expect(out.datasets.first?.sampleSize == 2)

            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let specs = try #require(setup.decodedManifest()?.datasets)
            #expect(specs == [DatasetSpec(file: "cases.csv", kind: .rowSample, sampleSize: 2)])

            // A dataset mark is not a content edit — the assignment stays open.
            let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(reloaded.visibility == .open)
        }
    }

    @Test func reMarkingReplacesTheSpecInPlace() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            _ = try await run(app, publicID: assignment.publicID, filename: "cases.csv", sampleSize: 2)
            let out = try await run(
                app, publicID: assignment.publicID, filename: "cases.csv", sampleSize: 3)
            #expect(out.datasets.count == 1)
            #expect(out.datasets.first?.sampleSize == 3)
        }
    }

    @Test func supportFileListingReportsTheMark() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            _ = try await run(app, publicID: assignment.publicID, filename: "cases.csv", sampleSize: 2)

            let listing = try await GetSupportFilesTool().execute(
                GetSupportFilesTool.Input(
                    assignmentPublicID: assignment.publicID, filename: nil, maxBytes: nil),
                context(app))
            let entry = try #require(listing.files?.first { $0.filename == "cases.csv" })
            #expect(entry.isDataset)
            #expect(entry.datasetSampleSize == 2)
        }
    }

    // MARK: - Clearing

    @Test func removeClearsTheMarkAndDropsTheManifestKey() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            _ = try await run(app, publicID: assignment.publicID, filename: "cases.csv", sampleSize: 2)

            let out = try await run(
                app, publicID: assignment.publicID, filename: "cases.csv", remove: true)
            #expect(out.datasets.isEmpty)

            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            #expect(setup.decodedManifest()?.datasets.isEmpty == true)
            #expect(setup.manifest.contains("\"datasets\"") == false)
        }
    }

    // MARK: - Validation

    @Test func rejectsMissingSampleSize() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await run(app, publicID: assignment.publicID, filename: "cases.csv")
            }
        }
    }

    @Test func rejectsNonPositiveSampleSize() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await run(
                    app, publicID: assignment.publicID, filename: "cases.csv", sampleSize: 0)
            }
        }
    }

    @Test func rejectsUnbundledFile() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await run(
                    app, publicID: assignment.publicID, filename: "missing.csv", sampleSize: 2)
            }
        }
    }

    @Test func rejectsGradedScriptAndNotebooks() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            for name in ["test_a.sh", "assignment.ipynb", "solution.ipynb"] {
                await #expect(throws: MCPToolError.self, "\(name) must be rejected") {
                    _ = try await run(
                        app, publicID: assignment.publicID, filename: name, sampleSize: 2)
                }
            }
        }
    }

    @Test func rejectsPathTraversal() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await run(
                    app, publicID: assignment.publicID, filename: "../cases.csv", sampleSize: 2)
            }
        }
    }

    // MARK: - Stratified sampling
    //
    // The fixture's `cases.csv` is `caseid,age` with three rows, so `age` is a
    // three-category column — small enough that the sample-size rule bites at
    // 2 and passes at 3.

    @Test func marksAStratifiedDataset() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let out = try await run(
                app, publicID: assignment.publicID, filename: "cases.csv",
                sampleSize: 3, stratumColumn: "age")
            #expect(out.datasets.first?.kind == "stratifiedSample")
            #expect(out.datasets.first?.stratumColumn == "age")

            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            #expect(
                setup.decodedManifest()?.datasets == [
                    DatasetSpec(
                        file: "cases.csv", kind: .stratifiedSample, sampleSize: 3, stratumColumn: "age")
                ])
        }
    }

    @Test func supportFileListingReportsTheStratum() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            _ = try await run(
                app, publicID: assignment.publicID, filename: "cases.csv",
                sampleSize: 3, stratumColumn: "age")

            let listing = try await GetSupportFilesTool().execute(
                GetSupportFilesTool.Input(
                    assignmentPublicID: assignment.publicID, filename: nil, maxBytes: nil),
                context(app))
            let entry = try #require(listing.files?.first { $0.filename == "cases.csv" })
            #expect(entry.datasetKind == "stratifiedSample")
            #expect(entry.datasetStratumColumn == "age")
        }
    }

    @Test func aPlainMarkReportsItsKindToo() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            _ = try await run(app, publicID: assignment.publicID, filename: "cases.csv", sampleSize: 2)

            let listing = try await GetSupportFilesTool().execute(
                GetSupportFilesTool.Input(
                    assignmentPublicID: assignment.publicID, filename: nil, maxBytes: nil),
                context(app))
            let entry = try #require(listing.files?.first { $0.filename == "cases.csv" })
            #expect(entry.datasetKind == "rowSample")
            #expect(entry.datasetStratumColumn == nil)
        }
    }

    @Test func rejectsAColumnTheFileDoesNotHave() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await run(
                    app, publicID: assignment.publicID, filename: "cases.csv",
                    sampleSize: 3, stratumColumn: "ward")
            }
        }
    }

    @Test func rejectsASampleTooSmallToHoldEveryCategory() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            // Three distinct ages, two rows to give out.
            await #expect(throws: MCPToolError.self) {
                _ = try await run(
                    app, publicID: assignment.publicID, filename: "cases.csv",
                    sampleSize: 2, stratumColumn: "age")
            }
        }
    }

    @Test func aBlankColumnMeansAPlainRowSample() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let out = try await run(
                app, publicID: assignment.publicID, filename: "cases.csv",
                sampleSize: 2, stratumColumn: "   ")
            #expect(out.datasets.first?.kind == "rowSample")
            #expect(out.datasets.first?.stratumColumn == nil)
        }
    }

    // MARK: - Transforms

    private func blanking(_ columns: [String], rate: Double?) -> SetDatasetTool.TransformInput {
        SetDatasetTool.TransformInput(kind: "missingValues", columns: columns, rate: rate)
    }

    @Test func storesAndReportsATransform() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let out = try await run(
                app, publicID: assignment.publicID, filename: "cases.csv", sampleSize: 2,
                transforms: [blanking(["age"], rate: 0.5)])

            #expect(out.datasets.first?.transforms.map(\.kind) == ["missingValues"])
            #expect(out.datasets.first?.transforms.first?.columns == ["age"])
            #expect(out.datasets.first?.transforms.first?.rate == 0.5)

            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let specs = try #require(setup.decodedManifest()?.datasets)
            #expect(
                specs.first?.transforms == [
                    DatasetTransform(kind: .missingValues, columns: ["age"], rate: 0.5)
                ])
        }
    }

    /// The shape that has twice come within a release of shipping: a surface
    /// rebuilding a spec from only the fields it knows about, so an edit to one
    /// setting drops another. Changing the sample size must not clear the
    /// transforms the caller did not mention.
    @Test func anUnrelatedEditPreservesTransforms() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            _ = try await run(
                app, publicID: assignment.publicID, filename: "cases.csv", sampleSize: 2,
                transforms: [blanking(["age"], rate: 0.5)])

            // A second call that says nothing about transforms.
            let out = try await run(
                app, publicID: assignment.publicID, filename: "cases.csv", sampleSize: 3)

            #expect(out.datasets.first?.sampleSize == 3)
            #expect(
                out.datasets.first?.transforms.first?.columns == ["age"],
                "an edit to sampleSize must not drop the transform")
        }
    }

    @Test func anEmptyTransformListClearsThem() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            _ = try await run(
                app, publicID: assignment.publicID, filename: "cases.csv", sampleSize: 2,
                transforms: [blanking(["age"], rate: 0.5)])

            // Explicitly [] is the caller saying so, unlike omitting the field.
            let out = try await run(
                app, publicID: assignment.publicID, filename: "cases.csv", sampleSize: 2,
                transforms: [])
            #expect(out.datasets.first?.transforms.isEmpty == true)
        }
    }

    @Test func refusesATransformNamingAColumnTheFileDoesNotHave() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                try await run(
                    app, publicID: assignment.publicID, filename: "cases.csv", sampleSize: 2,
                    transforms: [blanking(["nope"], rate: 0.5)])
            }
        }
    }

    @Test func refusesATransformWithNoRate() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                try await run(
                    app, publicID: assignment.publicID, filename: "cases.csv", sampleSize: 2,
                    transforms: [blanking(["age"], rate: nil)])
            }
        }
    }
}
