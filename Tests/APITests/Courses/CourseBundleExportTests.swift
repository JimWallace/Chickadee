// Tests/APITests/Courses/CourseBundleExportTests.swift
//
// Integration tests for course bundle export:
//
//   GET  /admin/courses/:courseID/export  — stream a bundle ZIP (admin only)
//
// Closes #69.
//
// Split out of the former CourseBundleTests.swift; the shared fixtures are in
// CourseBundleRouteFixtures.swift.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class CourseBundleExportTests: CourseBundleRouteFixtures {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-cbtest-export")
    }

    // MARK: - GET /admin/courses/:courseID/export

    @Test func exportRequiresAdmin() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent("teststudent_cb", on: app)
            let course = try await makeTestCourse(code: "EXP_AUTH")
            let id = try course.requireID().uuidString

            try await app.asyncTest(
                .GET, "/admin/courses/\(id)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.status == .forbidden) }
            )

        }
    }

    @Test func exportNotFoundForUnknownCourse() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            try await app.asyncTest(
                .GET, "/admin/courses/\(UUID().uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.status == .notFound) }
            )

        }
    }

    @Test func exportEmptyCourseReturnsZip() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let course = try await makeTestCourse(code: "EXP_EMPTY")
            let id = try course.requireID().uuidString

            try await app.asyncTest(
                .GET, "/admin/courses/\(id)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(
                        res.headers.first(name: .contentType)?.contains("zip") == true,
                        "Expected application/zip, got: \(res.headers.first(name: .contentType) ?? "(none)")"
                    )
                    #expect(res.headers.first(name: .contentDisposition)?.contains(".zip") == true)
                }
            )

        }
    }

    /// Export leaves out a submission whose file is gone, with its result,
    /// so the manifest names only files the bundle holds and the bundle
    /// imports (#2165).
    @Test func exportLeavesOutASubmissionWhoseFileIsMissing() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let course = try await makeTestCourse(code: "EXP_GONE")
            let courseID = try course.requireID()
            let setup = try await insertSetupWithZip(id: "setup_exp_gone", courseID: courseID)
            let setupID = try setup.requireID()
            try await insertAssignment(testSetupID: setupID, courseID: courseID)
            let student = try await makeTestUser(on: app, username: "gone_student", role: "student")
            try await makeTestEnrollment(on: app, userID: student.requireID(), courseID: courseID)
            _ = try await makeTestSubmission(
                on: app, id: "sub_exp_kept", setupID: setupID, userID: try student.requireID())
            let gone = try await makeTestSubmission(
                on: app, id: "sub_exp_gone", setupID: setupID, userID: try student.requireID())
            _ = try await makeTestResult(on: app, submissionID: "sub_exp_gone")
            try FileManager.default.removeItem(atPath: gone.zipPath)

            var zipData = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    zipData = Data(res.body.readableBytesView)
                }
            )
            let manifest = try await exportedManifest(zipData)
            #expect(manifest.submissions.map(\.bundleID) == ["sub_1"])
            #expect(manifest.results.isEmpty)

            course.isArchived = true
            try await course.save(on: app.db)
            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .badRequest, "Import failed: \(body.prefix(200))")
            let imported = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "EXP_GONE")
                    .filter(\.$isArchived == false)
                    .first())
            let importedAssignment = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$courseID == (try imported.requireID())).first())
            let importedCount = try await APISubmission.query(on: app.db)
                .filter(\.$testSetupID == importedAssignment.testSetupID)
                .count()
            #expect(importedCount == 1)
        }
    }

    /// A setup zip is the assignment's content, so an export with one
    /// missing fails and names the path instead of writing a bundle the
    /// import would refuse (#2165).
    @Test func exportFailsWhenASetupZipIsMissing() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let course = try await makeTestCourse(code: "EXP_NOZIP")
            let courseID = try course.requireID()
            let setup = try await insertSetupWithZip(id: "setup_exp_nozip", courseID: courseID)
            try await insertAssignment(testSetupID: (try setup.requireID()), courseID: courseID)
            try FileManager.default.removeItem(atPath: setup.zipPath)

            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .internalServerError)
                }
            )
        }
    }

    /// Decodes `bundle.json` out of an exported bundle.
    private func exportedManifest(_ zipData: Data) async throws -> CourseBundleManifest {
        let zipPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("exp-verify-\(UUID().uuidString).zip").path
        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("exp-extract-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(atPath: zipPath)
            try? FileManager.default.removeItem(at: extractDir)
        }
        try zipData.write(to: URL(fileURLWithPath: zipPath))
        try await extractZipArchive(zipPath: zipPath, into: extractDir)
        let manifestData = try Data(contentsOf: extractDir.appendingPathComponent("bundle.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CourseBundleManifest.self, from: manifestData)
    }

    @Test func exportManifestContainsCorrectCounts() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let course = try await makeTestCourse(code: "EXP_COUNTS")
            let courseID = try course.requireID()

            let setup = try await insertSetupWithZip(id: "setup_exp_c1", courseID: courseID)
            try await insertAssignment(testSetupID: (try setup.requireID()), courseID: courseID)

            var zipData = Data()
            try await app.asyncTest(
                .GET, "/admin/courses/\(courseID.uuidString)/export",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    zipData = Data(res.body.readableBytesView)
                }
            )

            // Extract the ZIP and parse bundle.json
            let zipPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("exp-verify-\(UUID().uuidString).zip").path
            let extractDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("exp-extract-\(UUID().uuidString)", isDirectory: true)
            defer {
                try? FileManager.default.removeItem(atPath: zipPath)
                try? FileManager.default.removeItem(at: extractDir)
            }

            try zipData.write(to: URL(fileURLWithPath: zipPath))
            try await extractZipArchive(zipPath: zipPath, into: extractDir)

            let manifestData = try Data(contentsOf: extractDir.appendingPathComponent("bundle.json"))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(CourseBundleManifest.self, from: manifestData)

            #expect(manifest.schemaVersion == 1)
            #expect(manifest.course.code == "EXP_COUNTS")
            #expect(manifest.testSetups.count == 1)
            #expect(manifest.assignments.count == 1)
            #expect(manifest.assignments.first?.title == "Test Lab")
            #expect(manifest.submissions.isEmpty)

        }
    }
}
