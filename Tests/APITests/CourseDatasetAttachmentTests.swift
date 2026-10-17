// Tests/APITests/CourseDatasetAttachmentTests.swift
//
// Attaching a course library dataset to an assignment
// (docs/datasets-course-library.md, slice 3): attach copies a version's bytes
// into the setup zip and records the source; update re-copies another version
// and keeps the sample; detach keeps the student's sample; promote moves a
// support file into the library without changing its bytes; and the doors
// that bring a whole manifest keep the invariant that a source names the
// file's own bytes.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class CourseDatasetAttachmentTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-ds-attach")
    }

    private var directory: String { app.testSetupsDirectory }
    private var blobs: AssignmentVersionBlobStore { AssignmentVersionBlobStore(testSetupsDirectory: directory) }

    private let versionOne = "id,ward,systolic\n1,A,120\n2,B,131\n3,A,118\n4,B,125\n5,A,140\n"
    private let versionTwo = "id,ward,systolic\n1,A,121\n2,B,131\n3,A,118\n4,B,125\n5,A,140\n6,B,119\n"

    private let manifest = """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test_a.sh"}],\
        "timeLimitSeconds":10,"makefile":null}
        """

    private struct Fixture {
        let courseID: UUID
        let setup: APITestSetup
        let dataset: APICourseDataset
    }

    /// A course with a setup whose zip holds a test and `notes.csv`, and a
    /// library dataset with versions 1 and 2.
    private func fixture(code: String, manifest manifestText: String? = nil) async throws -> Fixture {
        let courseID = try await makeTestCourse(on: app, code: code, name: code).requireID()
        let setupID = "att_\(UUID().uuidString.prefix(8))"
        try await writeZipFixture(
            at: directory + setupID + ".zip",
            entries: [("test_a.sh", "exit 0\n"), ("notes.csv", "id,score\n1,4\n2,5\n")])
        let setup = try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: manifestText ?? manifest, withNotebook: false,
            withZip: false)
        let dataset = try await CourseDatasetService.create(
            courseID: courseID,
            dataset: .init(
                name: "VitalDB cases", slug: "vitaldb-cases", description: nil, provenance: nil, licence: nil),
            upload: .init(filename: "cases.csv", bytes: Data(versionOne.utf8), note: nil), blobs: blobs, on: app.db
        ).dataset
        _ = try await CourseDatasetService.addVersion(
            to: dataset, upload: .init(filename: "cases.csv", bytes: Data(versionTwo.utf8), note: nil), blobs: blobs,
            on: app.db)
        return Fixture(courseID: courseID, setup: setup, dataset: dataset)
    }

    private func request(
        version: Int? = 1, filename: String? = nil, sampleSize: Int? = 3, stratum: String? = nil,
        scope: DatasetSliceScope = .assignment
    ) -> CourseDatasetService.AttachRequest {
        .init(version: version, filename: filename, sampleSize: sampleSize, stratumColumn: stratum, scope: scope)
    }

    private func reload(_ setup: APITestSetup) async throws -> APITestSetup {
        try #require(try await APITestSetup.find(setup.id, on: app.db))
    }

    private func zipText(_ setup: APITestSetup, _ name: String) async -> String? {
        await readScriptFromZip(zipPath: setup.zipPath, filename: name)
    }

    // MARK: - Attach

    @Test func attachCopiesTheVersionAndRecordsTheSource() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(code: "ATT1")
            let spec = try await CourseDatasetService.attach(
                fx.dataset, to: fx.setup, request: request(scope: .course), testSetupsDirectory: directory,
                on: app.db)

            #expect(spec.source == DatasetSource(slug: "vitaldb-cases", version: 1))
            #expect(spec.scope == .course)
            #expect(spec.sampleSize == 3)
            let setup = try await reload(fx.setup)
            #expect(setup.decodedManifest()?.datasets == [spec])
            #expect(await zipText(setup, "cases.csv") == versionOne)
            let shared = directory + "shared/\(try #require(setup.id))/cases.csv"
            #expect(FileManager.default.fileExists(atPath: shared))
            #expect(try await CourseDatasetService.usage(of: fx.dataset, on: app.db).map(\.file) == ["cases.csv"])
        }
    }

    @Test func attachingTheWholeFileDeliversItUnchanged() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(code: "ATT2")
            let spec = try await CourseDatasetService.attach(
                fx.dataset, to: fx.setup, request: request(version: nil, filename: "pool.csv", sampleSize: nil),
                testSetupsDirectory: directory, on: app.db)
            #expect(spec.sampleSize == nil)
            #expect(spec.source?.version == 2)
            let setup = try await reload(fx.setup)
            let delivered = DatasetResolver.resolve(
                manifest: try #require(setup.decodedManifest()), seedHex: String(repeating: "ab", count: 32),
                sourceDirectory: directory + "shared/\(try #require(setup.id))/")
            #expect(delivered?["pool.csv"] == versionTwo)
        }
    }

    @Test func attachRefusesADatasetFromAnotherCourse() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(code: "ATT3")
            let other = try await fixture(code: "ATT3X")
            await #expect(throws: CourseDatasetError.wrongCourse) {
                try await CourseDatasetService.attach(
                    other.dataset, to: fx.setup, request: self.request(), testSetupsDirectory: self.directory,
                    on: app.db)
            }
        }
    }

    @Test(arguments: [
        ("notes.csv", CourseDatasetError.fileTaken("notes.csv")),
        ("test_a.sh", .invalidFilename("test_a.sh")),
    ])
    func attachRefusesANameThatIsTaken(filename: String, expected: CourseDatasetError) async throws {
        try await withApp(app) { app in
            let fx = try await fixture(code: "ATT4\(filename.prefix(1))")
            await #expect(throws: expected) {
                try await CourseDatasetService.attach(
                    fx.dataset, to: fx.setup, request: self.request(filename: filename),
                    testSetupsDirectory: self.directory, on: app.db)
            }
            #expect(try await self.reload(fx.setup).decodedManifest()?.datasets.isEmpty == true)
        }
    }

    @Test func attachRefusesASpecTheFileCannotHold() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(code: "ATT5")
            await #expect(throws: CourseDatasetError.self) {
                try await CourseDatasetService.attach(
                    fx.dataset, to: fx.setup, request: self.request(stratum: "unit"),
                    testSetupsDirectory: self.directory, on: app.db)
            }
            #expect(await self.zipText(fx.setup, "cases.csv") == nil)
        }
    }

    @Test func attachRefusesADeletedDataset() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(code: "ATT6")
            try await CourseDatasetService.delete(fx.dataset, on: app.db)
            await #expect(throws: CourseDatasetError.datasetGone) {
                try await CourseDatasetService.attach(
                    fx.dataset, to: fx.setup, request: self.request(), testSetupsDirectory: self.directory,
                    on: app.db)
            }
        }
    }

    @Test func attachingTheSameFileTwiceIsRefused() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(code: "ATT7")
            try await CourseDatasetService.attach(
                fx.dataset, to: fx.setup, request: request(), testSetupsDirectory: directory, on: app.db)
            await #expect(throws: CourseDatasetError.alreadyAttached("cases.csv")) {
                try await CourseDatasetService.attach(
                    fx.dataset, to: try await self.reload(fx.setup), request: self.request(),
                    testSetupsDirectory: self.directory, on: app.db)
            }
        }
    }

    // MARK: - Update

    @Test func updateCopiesTheNewVersionAndKeepsTheSample() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(code: "ATT8")
            try await CourseDatasetService.attach(
                fx.dataset, to: fx.setup, request: request(stratum: "ward", scope: .course),
                testSetupsDirectory: directory, on: app.db)
            var setup = try await reload(fx.setup)
            let refreshed = try #require(try await APICourseDataset.find(fx.dataset.id, on: app.db))
            let attached = try #require(setup.decodedManifest()?.libraryAttachment(for: "cases.csv"))
            #expect(CourseDatasetService.attachmentIsBehind(attached, dataset: refreshed))

            let spec = try await CourseDatasetService.updateAttachment(
                file: "cases.csv", in: setup, to: nil, testSetupsDirectory: directory, on: app.db)
            #expect(spec.source?.version == 2)
            #expect(spec.kind == .stratifiedSample)
            #expect(spec.stratumColumn == "ward")
            #expect(spec.sampleSize == 3)
            #expect(spec.scope == .course)
            setup = try await reload(setup)
            #expect(await zipText(setup, "cases.csv") == versionTwo)
            #expect(!CourseDatasetService.attachmentIsBehind(spec, dataset: refreshed))

            await #expect(throws: CourseDatasetError.alreadyAtVersion(2)) {
                try await CourseDatasetService.updateAttachment(
                    file: "cases.csv", in: setup, to: 2, testSetupsDirectory: self.directory, on: app.db)
            }
        }
    }

    @Test func updateRefusesAVersionTheSampleCannotUse() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(code: "ATT9")
            try await CourseDatasetService.attach(
                fx.dataset, to: fx.setup, request: request(stratum: "ward"), testSetupsDirectory: directory,
                on: app.db)
            _ = try await CourseDatasetService.addVersion(
                to: fx.dataset,
                upload: .init(filename: "cases.csv", bytes: Data("id,unit\n1,X\n2,Y\n".utf8), note: nil),
                blobs: blobs, on: app.db)
            let setup = try await reload(fx.setup)
            await #expect(throws: CourseDatasetError.self) {
                try await CourseDatasetService.updateAttachment(
                    file: "cases.csv", in: setup, to: 3, testSetupsDirectory: self.directory, on: app.db)
            }
            #expect(await self.zipText(setup, "cases.csv") == self.versionOne)
        }
    }

    // MARK: - Detach

    @Test func detachKeepsTheFileAndTheSample() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(code: "ATT10")
            try await CourseDatasetService.attach(
                fx.dataset, to: fx.setup, request: request(scope: .course), testSetupsDirectory: directory,
                on: app.db)
            try await CourseDatasetService.detach(
                file: "cases.csv", from: try await reload(fx.setup), removeFile: false,
                testSetupsDirectory: directory, on: app.db)
            let setup = try await reload(fx.setup)
            #expect(setup.decodedManifest()?.datasets == [DatasetSpec(file: "cases.csv", sampleSize: 3)])
            #expect(await zipText(setup, "cases.csv") == versionOne)
            #expect(try await CourseDatasetService.usage(of: fx.dataset, on: app.db).isEmpty)
        }
    }

    @Test func detachingAWholeFileLeavesAPlainSupportFile() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(code: "ATT11")
            try await CourseDatasetService.attach(
                fx.dataset, to: fx.setup, request: request(sampleSize: nil), testSetupsDirectory: directory,
                on: app.db)
            try await CourseDatasetService.detach(
                file: "cases.csv", from: try await reload(fx.setup), removeFile: false,
                testSetupsDirectory: directory, on: app.db)
            let setup = try await reload(fx.setup)
            #expect(setup.decodedManifest()?.datasets.isEmpty == true)
            #expect(await zipText(setup, "cases.csv") == versionOne)
        }
    }

    @Test func detachCanRemoveTheFile() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(code: "ATT12")
            try await CourseDatasetService.attach(
                fx.dataset, to: fx.setup, request: request(), testSetupsDirectory: directory, on: app.db)
            try await CourseDatasetService.detach(
                file: "cases.csv", from: try await reload(fx.setup), removeFile: true,
                testSetupsDirectory: directory, on: app.db)
            let setup = try await reload(fx.setup)
            #expect(setup.decodedManifest()?.datasets.isEmpty == true)
            #expect(await zipText(setup, "cases.csv") == nil)
            await #expect(throws: CourseDatasetError.notAttached("cases.csv")) {
                try await CourseDatasetService.detach(
                    file: "cases.csv", from: setup, removeFile: false, testSetupsDirectory: self.directory,
                    on: app.db)
            }
        }
    }

    // MARK: - Promote

    @Test func promoteMovesASupportFileIntoTheLibraryWithoutChangingIt() async throws {
        try await withApp(app) { app in
            let withSample = """
                {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test_a.sh"}],\
                "timeLimitSeconds":10,"makefile":null,"datasets":[{"file":"notes.csv","sampleSize":1}]}
                """
            let fx = try await fixture(code: "ATT13", manifest: withSample)
            let (dataset, spec) = try await CourseDatasetService.promote(
                file: "notes.csv", from: fx.setup,
                dataset: .init(name: "Notes", slug: "notes", description: nil, provenance: nil, licence: nil),
                testSetupsDirectory: directory, on: app.db)

            #expect(dataset.currentVersion == 1)
            #expect(
                spec == DatasetSpec(file: "notes.csv", sampleSize: 1, source: DatasetSource(slug: "notes", version: 1)))
            let setup = try await reload(fx.setup)
            #expect(setup.decodedManifest()?.datasets == [spec])
            #expect(try await CourseDatasetService.usage(of: dataset, on: app.db).count == 1)
            #expect(
                try await CourseDatasetService.sourceIssue(
                    for: spec, courseID: fx.courseID, zipPath: setup.zipPath, on: app.db) == nil)
        }
    }

    @Test func promoteRefusesATest() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(code: "ATT14")
            await #expect(throws: CourseDatasetError.notASupportFile("test_a.sh")) {
                _ = try await CourseDatasetService.promote(
                    file: "test_a.sh", from: fx.setup,
                    dataset: .init(name: "T", slug: "t", description: nil, provenance: nil, licence: nil),
                    testSetupsDirectory: self.directory, on: app.db)
            }
        }
    }

    // MARK: - Doors that bring a whole manifest

    @Test func sourceIssueChecksTheDatasetTheVersionAndTheBytes() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(code: "ATT15")
            try await CourseDatasetService.attach(
                fx.dataset, to: fx.setup, request: request(), testSetupsDirectory: directory, on: app.db)
            let zip = fx.setup.zipPath
            let check = { (spec: DatasetSpec) in
                try await CourseDatasetService.sourceIssue(for: spec, courseID: fx.courseID, zipPath: zip, on: app.db)
            }
            #expect(
                try await check(DatasetSpec(file: "cases.csv", source: .init(slug: "vitaldb-cases", version: 1))) == nil
            )
            #expect(
                try await check(DatasetSpec(file: "cases.csv", source: .init(slug: "vitaldb-cases", version: 2))) != nil
            )
            #expect(
                try await check(DatasetSpec(file: "cases.csv", source: .init(slug: "vitaldb-cases", version: 9))) != nil
            )
            #expect(try await check(DatasetSpec(file: "cases.csv", source: .init(slug: "nhanes", version: 1))) != nil)
            #expect(try await check(DatasetSpec(file: "notes.csv", scope: .course)) != nil)
            #expect(try await check(DatasetSpec(file: "notes.csv", sampleSize: 1)) == nil)
        }
    }

    @Test func aManifestWithNothingToReconcileKeepsItsBytes() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(code: "ATT16")
            try await CourseDatasetService.attach(
                fx.dataset, to: fx.setup, request: request(), testSetupsDirectory: directory, on: app.db)
            let setup = try await reload(fx.setup)
            #expect(
                try await CourseDatasetService.reconciledManifestText(
                    setup.manifest, courseID: fx.courseID, zipPath: setup.zipPath, on: app.db) == setup.manifest)
            #expect(
                try await CourseDatasetService.reconciledManifestText(
                    manifest, courseID: fx.courseID, zipPath: setup.zipPath, on: app.db) == manifest)
        }
    }

    @Test func reconcilingIntoAnotherCourseDropsTheSourceAndKeepsTheSample() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(code: "ATT17")
            try await CourseDatasetService.attach(
                fx.dataset, to: fx.setup, request: request(scope: .course), testSetupsDirectory: directory,
                on: app.db)
            try await CourseDatasetService.attach(
                fx.dataset, to: try await reload(fx.setup), request: request(filename: "pool.csv", sampleSize: nil),
                testSetupsDirectory: directory, on: app.db)
            let setup = try await reload(fx.setup)
            let elsewhere = try await makeTestCourse(on: app, code: "ATT17X", name: "Elsewhere").requireID()
            let text = try await CourseDatasetService.reconciledManifestText(
                setup.manifest, courseID: elsewhere, zipPath: setup.zipPath, on: app.db)
            let props = try #require(decodeManifest(fromJSON: text))
            #expect(props.datasets == [DatasetSpec(file: "cases.csv", sampleSize: 3)])
        }
    }

    @Test func aCloneIntoAnotherCourseDropsTheLibrarySources() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(code: "ATT18")
            try await CourseDatasetService.attach(
                fx.dataset, to: fx.setup, request: request(), testSetupsDirectory: directory, on: app.db)
            let source = try await makeTestAssignment(
                on: app, testSetupID: try #require(fx.setup.id), courseID: fx.courseID, title: "Cohort lab")
            let target = try await makeTestCourse(on: app, code: "ATT18X", name: "Next term").requireID()
            let cloned = try await AssignmentAuthoringService.cloneAssignment(
                source: source, sourceSetup: try await reload(fx.setup), newTitle: "Cohort lab", targetCourseID: target,
                directories: AuthoringDirectories(setups: directory, submissions: app.submissionsDirectory),
                on: app.db)
            #expect(cloned.setup.decodedManifest()?.datasets == [DatasetSpec(file: "cases.csv", sampleSize: 3)])
            #expect(await zipText(cloned.setup, "cases.csv") == versionOne)
        }
    }

    @Test func aCloneInsideTheCourseKeepsTheLibrarySources() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(code: "ATT19")
            let spec = try await CourseDatasetService.attach(
                fx.dataset, to: fx.setup, request: request(), testSetupsDirectory: directory, on: app.db)
            let source = try await makeTestAssignment(
                on: app, testSetupID: try #require(fx.setup.id), courseID: fx.courseID, title: "Cohort lab")
            let cloned = try await AssignmentAuthoringService.cloneAssignment(
                source: source, sourceSetup: try await reload(fx.setup), newTitle: "Cohort lab copy",
                targetCourseID: fx.courseID,
                directories: AuthoringDirectories(setups: directory, submissions: app.submissionsDirectory),
                on: app.db)
            #expect(cloned.setup.decodedManifest()?.datasets == [spec])
        }
    }
}
