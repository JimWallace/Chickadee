// Tests/APITests/Courses/CourseBundleImportValidationTests.swift
//
// Integration tests for course bundle import access control and validation:
//
//   POST /admin/courses/import  — accept an uploaded bundle ZIP (admin only)
//
// Closes #70.
//
// Split out of the former CourseBundleTests.swift; the shared fixtures are in
// CourseBundleRouteFixtures.swift.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class CourseBundleImportValidationTests: CourseBundleRouteFixtures {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-cbtest-impval")
    }

    // MARK: - POST /admin/courses/import — access control

    @Test func importRequiresAdmin() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent("teststudent_cb", on: app)
            let zipData = try await makeMinimalBundleZip(courseCode: "IMP_AUTH")
            let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status == .forbidden)

        }
    }

    // MARK: - POST /admin/courses/import — validation errors

    @Test func importRejectsMissingBundleJSON() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)

            let stagingDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cb-no-manifest-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            try "placeholder".write(
                to: stagingDir.appendingPathComponent("readme.txt"),
                atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: stagingDir) }

            let zipData = try await zipDir(stagingDir)
            let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status == .badRequest)

        }
    }

    @Test func importRejectsInvalidBundleJSON() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)

            let stagingDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cb-bad-json-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            try "this is not json!!!".write(
                to: stagingDir.appendingPathComponent("bundle.json"),
                atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: stagingDir) }

            let zipData = try await zipDir(stagingDir)
            let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status == .badRequest)

        }
    }

    @Test func importRejectsWrongSchemaVersion() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)

            let badJSON = """
                {"schemaVersion":99,"exportedAt":"2026-01-01T00:00:00Z","exportedBy":"admin",
                 "chickadeeVersion":"0.2.0","course":{"code":"BADVER","name":"X"},
                 "users":[],"enrolledUserBundleIDs":[],"assignments":[],
                 "testSetups":[],"submissions":[],"results":[]}
                """
            let stagingDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cb-bad-ver-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            try badJSON.write(
                to: stagingDir.appendingPathComponent("bundle.json"),
                atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: stagingDir) }

            let zipData = try await zipDir(stagingDir)
            let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status == .badRequest)

        }
    }

    @Test func importRejectsMissingSetupFile() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)

            // Manifest references a setup zip that isn't in the archive
            let badJSON = """
                {"schemaVersion":1,"exportedAt":"2026-01-01T00:00:00Z","exportedBy":"admin",
                 "chickadeeVersion":"0.2.0","course":{"code":"MISSING_FILE","name":"X"},
                 "users":[],"enrolledUserBundleIDs":[],"assignments":[],
                 "testSetups":[{"bundleID":"setup_1","originalID":"setup_ghost",
                                "manifest":"{}","zipFilename":"testsetups/setup_ghost.zip"}],
                 "submissions":[],"results":[]}
                """
            let stagingDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cb-missing-file-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            // Deliberately NOT writing testsetups/setup_ghost.zip
            try badJSON.write(
                to: stagingDir.appendingPathComponent("bundle.json"),
                atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: stagingDir) }

            let zipData = try await zipDir(stagingDir)
            let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status == .badRequest)

        }
    }

    /// A content item kind this server does not know is refused with its
    /// name, not imported as a link in silence (#2172).
    @Test func importRejectsAnUnknownContentItemKind() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let zipData = try await makeMinimalBundleZip(
                courseCode: "UNKNOWN_KIND",
                contentItems: [
                    BundledContentItem(
                        sectionBundleID: nil, title: "Week 1", kind: "hologram", description: nil,
                        links: [], updatedLabel: nil, isPublished: true, sortOrder: 1)
                ])
            let (status, body) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status == .badRequest)
            #expect(body.contains("hologram"))
            #expect(body.contains("Week 1"))
            let count = try await APICourse.query(on: app.db).filter(\.$code == "UNKNOWN_KIND").count()
            #expect(count == 0)
        }
    }

    /// A section's legacy grading mode is read by nothing, so even a value
    /// this server does not know imports, with the section's name.
    @Test func importIgnoresASectionsLegacyGradingMode() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let zipData = try await makeMinimalBundleZip(
                courseCode: "UNKNOWN_MODE",
                sections: [
                    BundledSection(
                        bundleID: "section_1", name: "Labs", defaultGradingMode: "quantum", sortOrder: 1)
                ])
            let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status != .badRequest)
            let course = try #require(
                try await APICourse.query(on: app.db).filter(\.$code == "UNKNOWN_MODE").first())
            let sections = try await APICourseSection.query(on: app.db)
                .filter(\.$courseID == course.requireID()).all()
            #expect(sections.map(\.name) == ["Labs"])
        }
    }

    @Test func importRejectsActiveCourseDuplicate() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            _ = try await makeTestCourse(code: "DUPLICATE101")  // active course

            let zipData = try await makeMinimalBundleZip(courseCode: "DUPLICATE101")
            let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
            #expect(status == .conflict)

        }
    }

    @Test func importAllowsArchivedCourseDuplicate() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("testadmin_cb", on: app)
            let archived = try await makeTestCourse(code: "ARCHIVED_IMP")
            archived.isArchived = true
            try await archived.save(on: app.db)

            let zipData = try await makeMinimalBundleZip(courseCode: "ARCHIVED_IMP")
            let (status, _) = try await postImport(cookie: cookie, zipData: zipData)
            // Whatever the page does, NOT a 4xx rejection
            #expect(status != .conflict)
            #expect(status != .forbidden)
            #expect(status != .badRequest)

        }
    }
}
