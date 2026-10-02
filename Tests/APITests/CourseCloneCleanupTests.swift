// Tests/APITests/CourseCloneCleanupTests.swift
//
// A course clone that fails part-way leaves no files behind (#1743). The
// caller runs the clone inside a transaction, so the rows of the earlier
// copies roll back; the service removes the files those copies wrote.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(10))) final class CourseCloneCleanupTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-clone-cleanup")
    }

    /// Everything under `directory` except the version blob store, which is
    /// content-addressed and shared between assignments: a clone's seed may
    /// write blobs there, and the grace-window reaper, not the clone, owns
    /// them (#1743).
    private func listing(of directory: String) throws -> Set<String> {
        Set(
            try FileManager.default.subpathsOfDirectory(atPath: directory)
                .filter { $0 != "versions" && !$0.hasPrefix("versions/") })
    }

    /// Two assignments; the second source zip is gone, so its copy fails
    /// after the first assignment's zip, notebook and shared directory were
    /// written. Afterwards the setups and submissions directories hold
    /// exactly what they held before, and no target course exists.
    @Test func aFailedCloneLeavesNoFilesFromTheEarlierCopies() async throws {
        try await withApp(app) { app in
            let course = APICourse(
                code: "CLX1", name: "Cleanup Source", enrollmentMode: .closed,
                term: AcademicTerm(year: 2026, season: .fall))
            try await course.save(on: app.db)
            let courseID = try course.requireID()
            try await makeTestSetup(on: app, id: "setup_clx_ok", courseID: courseID)
            let badSetup = try await makeTestSetup(on: app, id: "setup_clx_bad", courseID: courseID)
            let first = try await makeTestAssignment(
                on: app, testSetupID: "setup_clx_ok", courseID: courseID, title: "Lab 1")
            first.sortOrder = 1
            try await first.save(on: app.db)
            let second = try await makeTestAssignment(
                on: app, testSetupID: "setup_clx_bad", courseID: courseID, title: "Lab 2")
            second.sortOrder = 2
            try await second.save(on: app.db)
            try FileManager.default.removeItem(atPath: badSetup.zipPath)
            // The shared support directory outlives any one assignment, so it
            // exists before the clone: only its per-setup child must go.
            try FileManager.default.createDirectory(
                atPath: app.testSetupsDirectory + "shared/", withIntermediateDirectories: true)

            let setupsBefore = try listing(of: app.testSetupsDirectory)
            let submissionsBefore = try listing(of: app.submissionsDirectory)
            let directories = AuthoringDirectories(
                setups: app.testSetupsDirectory, submissions: app.submissionsDirectory)
            let target = CourseCloneTarget(
                code: "CLX2", name: "Cleanup Target", term: AcademicTerm(year: 2027, season: .winter))

            await #expect(throws: (any Error).self) {
                try await app.db.transaction { db in
                    _ = try await CourseCloneService.clone(
                        source: course, target: target, directories: directories,
                        contentFilesDirectory: app.contentFilesDirectory, on: db)
                }
            }

            #expect(try listing(of: app.testSetupsDirectory) == setupsBefore)
            #expect(try listing(of: app.submissionsDirectory) == submissionsBefore)
            #expect(try await APICourse.query(on: app.db).filter(\.$code == "CLX2").count() == 0)
        }
    }
}
