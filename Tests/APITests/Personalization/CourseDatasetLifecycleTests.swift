// Tests/APITests/Personalization/CourseDatasetLifecycleTests.swift
//
// The course dataset library through a course's lifecycle
// (docs/datasets-course-library.md §4.8). A clone copies every dataset and
// version, writes no bytes, and leaves each cloned assignment's library
// source in force in the new course (D10). A course delete takes the library
// rows, and then the blob collector reclaims a version's bytes unless another
// course's library still names them.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

/// The clone and the attach run `zip` and `unzip`, so the suite has a time
/// limit.
@Suite(.serialized, .timeLimit(.minutes(5))) final class CourseDatasetLifecycleTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-ds-lifecycle")
    }

    private var blobs: AssignmentVersionBlobStore {
        AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory)
    }

    private let versionOne = "id,ward,systolic\n1,A,120\n2,B,131\n3,A,118\n4,B,125\n5,A,140\n"
    private let versionTwo = "id,ward,systolic\n1,A,121\n2,B,131\n3,A,118\n4,B,125\n5,A,140\n6,B,119\n"

    /// A Fall 2026 course with a published dataset of two versions, and one
    /// assignment that attaches version 1 with a course-scoped sample.
    private func makeSource(code: String) async throws -> (course: APICourse, dataset: APICourseDataset) {
        let course = APICourse(
            code: code, name: code, enrollmentMode: .closed, term: AcademicTerm(year: 2026, season: .fall))
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        let dataset = try await CourseDatasetService.create(
            courseID: courseID,
            dataset: .init(
                name: "Ward cases", slug: "ward-cases", description: "Admissions by ward",
                provenance: "Hospital extract", licence: "Course use only"),
            upload: .init(filename: "cases.csv", bytes: Data(versionOne.utf8), note: "First cut"), blobs: blobs,
            on: app.db
        ).dataset
        try await CourseDatasetService.setPublished(dataset, true, on: app.db)
        _ = try await CourseDatasetService.addVersion(
            to: dataset, upload: .init(filename: "cases.csv", bytes: Data(versionTwo.utf8)), blobs: blobs,
            on: app.db)

        let setupID = "lc_\(UUID().uuidString.prefix(8))"
        try await writeZipFixture(at: app.testSetupsDirectory + setupID + ".zip", entries: [("test_a.sh", "exit 0\n")])
        let manifest = """
            {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test_a.sh"}],\
            "timeLimitSeconds":10,"makefile":null,"submissionMode":"uploadOnly"}
            """
        let setup = try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: manifest, withNotebook: false, withZip: false)
        _ = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID, title: "Lab 2")
        try await CourseDatasetService.attach(
            dataset, to: setup, request: .init(version: 1, sampleSize: 3, scope: .course),
            testSetupsDirectory: app.testSetupsDirectory, on: app.db)
        return (course, dataset)
    }

    private func clone(_ source: APICourse, code: String) async throws -> APICourse {
        let directories = AuthoringDirectories(setups: app.testSetupsDirectory, submissions: app.submissionsDirectory)
        let target = CourseCloneTarget(code: code, name: code, term: AcademicTerm(year: 2027, season: .winter))
        let contentFilesDirectory = app.contentFilesDirectory
        return try await app.db.transaction { db in
            try await CourseCloneService.clone(
                source: source, target: target, directories: directories,
                contentFilesDirectory: contentFilesDirectory, on: db
            ).course
        }
    }

    private func blobFiles() throws -> Set<String> {
        let directory = app.testSetupsDirectory + "versions/blobs/"
        guard let names = FileManager.default.enumerator(atPath: directory) else { return [] }
        return Set(names.compactMap { $0 as? String })
    }

    // MARK: - Clone

    @Test func aCloneCopiesEveryDatasetAndVersion() async throws {
        try await withApp(app) { app in
            let (source, dataset) = try await makeSource(code: "LCS1")
            let copy = try await clone(source, code: "LCS1")

            let copied = try #require(
                try await CourseDatasetService.find(courseID: try copy.requireID(), slug: "ward-cases", on: app.db))
            #expect(copied.name == "Ward cases")
            #expect(copied.provenance == "Hospital extract")
            #expect(copied.isPublished)
            #expect(copied.currentVersion == 2)
            let sourceVersions = try await CourseDatasetService.versions(of: dataset, on: app.db)
            let copiedVersions = try await CourseDatasetService.versions(of: copied, on: app.db)
            #expect(copiedVersions.map(\.version) == [1, 2])
            #expect(copiedVersions.map(\.sha256) == sourceVersions.map(\.sha256))
            #expect(copiedVersions.map(\.note) == sourceVersions.map(\.note))
            #expect(copiedVersions.map(\.columns) == sourceVersions.map(\.columns))

            // The source keeps its own library.
            #expect(try await CourseDatasetService.list(courseID: try source.requireID(), on: app.db).count == 1)
        }
    }

    /// The library copy writes rows only: the versions share their blobs by
    /// hash. (The clone's first version snapshot of each assignment writes
    /// blobs of its own, so this calls the library copy alone.)
    @Test func theLibraryCopyWritesNoBytes() async throws {
        try await withApp(app) { app in
            let (source, _) = try await makeSource(code: "LCS3")
            let target = try await makeTestCourse(on: app, code: "LCS3T").requireID()
            let blobsBefore = try blobFiles()
            #expect(
                try await CourseDatasetService.copyLibrary(from: try source.requireID(), to: target, on: app.db) == 1)
            #expect(try blobFiles() == blobsBefore)
        }
    }

    /// D10: the cloned assignment's file still comes from the library, now
    /// the new course's.
    @Test func aClonedAssignmentKeepsItsLibrarySourceInTheNewCourse() async throws {
        try await withApp(app) { app in
            let (source, _) = try await makeSource(code: "LCS2")
            let copy = try await clone(source, code: "LCS2")
            let copyID = try copy.requireID()
            let setup = try #require(try await APITestSetup.query(on: app.db).filter(\.$courseID == copyID).first())
            let spec = try #require(setup.decodedManifest()?.datasetSpecsByFile["cases.csv"])
            #expect(spec.source == DatasetSource(slug: "ward-cases", version: 1))
            #expect(spec.scope == .course)
            #expect(spec.sampleSize == 3)
            #expect(
                try await CourseDatasetService.sourceIssue(
                    for: spec, courseID: copyID, zipPath: setup.zipPath, on: app.db) == nil)
            let usage = try await CourseDatasetService.usage(
                of: try #require(
                    try await CourseDatasetService.find(courseID: copyID, slug: "ward-cases", on: app.db)),
                on: app.db)
            #expect(usage.map(\.file) == ["cases.csv"])
        }
    }

    // MARK: - Delete

    @Test func deletingACourseTakesItsLibraryRows() async throws {
        try await withApp(app) { app in
            let (source, dataset) = try await makeSource(code: "LCD1")
            let datasetID = try dataset.requireID()
            try await APICourse.query(on: app.db).filter(\.$id == (try source.requireID())).delete()
            #expect(try await APICourseDataset.find(datasetID, on: app.db) == nil)
            #expect(try await APICourseDatasetVersion.query(on: app.db).filter(\.$datasetID == datasetID).count() == 0)
        }
    }

    /// After a course delete, the collector reclaims the bytes only its
    /// library named. A clone's library names the same hashes, so they stay
    /// while the clone lives.
    @Test func theCollectorKeepsBytesThatAClonesLibraryStillNames() async throws {
        try await withApp(app) { app in
            let (source, dataset) = try await makeSource(code: "LCD2")
            let hashes = try await CourseDatasetService.versions(of: dataset, on: app.db).map(\.sha256)
            let copy = try await clone(source, code: "LCD2")

            func deleteAndCollect(_ course: APICourse) async throws {
                // The setups of the course go too, as the course delete removes
                // them; their zips would otherwise keep the bytes referenced.
                let courseID = try course.requireID()
                try await APIAssignment.query(on: app.db).filter(\.$courseID == courseID).delete()
                try await APITestSetup.query(on: app.db).filter(\.$courseID == courseID).delete()
                try await APICourse.query(on: app.db).filter(\.$id == courseID).delete()
                let referenced = try await AssignmentVersionStore.referencedBlobHashes(on: app.db)
                _ = self.blobs.collectGarbage(
                    referenced: referenced, graceSeconds: 0, now: Date().addingTimeInterval(86_400))
            }

            try await deleteAndCollect(source)
            for hash in hashes { #expect(self.blobs.exists(hash)) }
            try await deleteAndCollect(copy)
            for hash in hashes { #expect(!self.blobs.exists(hash)) }
        }
    }
}
