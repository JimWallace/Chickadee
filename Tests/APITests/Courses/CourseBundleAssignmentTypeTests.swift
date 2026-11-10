// Tests/APITests/Courses/CourseBundleAssignmentTypeTests.swift
//
// The declared assignment type travels with a course bundle and with a clone
// (docs/assignment-types.md). A bundled type wins over the derivation, so a
// Class activity declared on a setup with no activity block stays one.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class CourseBundleAssignmentTypeTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-cbtype")
    }

    private static let dummyZipBytes: [UInt8] = [0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)

    /// A course with one worker-graded assignment declared as `type`.
    private func typed(code: String, type: AssignmentType) async throws -> APICourse {
        let course = APICourse(code: code, name: "Type Bundle Course")
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        let setupID = "setup_\(code.lowercased())"
        let zipPath = app.testSetupsDirectory + "\(setupID).zip"
        try Data(Self.dummyZipBytes).write(to: URL(fileURLWithPath: zipPath))
        try await APITestSetup(
            id: setupID, manifest: TestManifests.workerEmptyExplicit, zipPath: zipPath, courseID: courseID
        ).save(on: app.db)
        let assignment = APIAssignment(
            testSetupID: setupID, title: "Pooled Testing", dueAt: nil, isOpen: true, courseID: courseID)
        assignment.assignmentType = type
        try await assignment.save(on: app.db)
        return course
    }

    private func export(_ courseID: UUID, cookie: String) async throws -> Data {
        var zipData = Data()
        try await app.asyncTest(
            .GET, "/admin/courses/\(courseID.uuidString)/export",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                #expect(res.status == .ok)
                zipData = Data(res.body.readableBytesView)
            })
        return zipData
    }

    private func postImport(cookie: String, zipData: Data) async throws -> HTTPStatus {
        let (csrf, sessionCookie) = try await csrfFields(for: "/admin", cookie: cookie, on: app)
        let boundary = "cbt-boundary-\(UUID().uuidString)"
        var body = ByteBuffer()
        body.writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n\(csrf)\r\n")
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"file\"; filename=\"bundle.zip\"\r\n")
        body.writeString("Content-Type: application/zip\r\n\r\n")
        body.writeBytes(zipData)
        body.writeString("\r\n--\(boundary)--\r\n")
        var status = HTTPStatus.internalServerError
        try await app.asyncTest(
            .POST, "/admin/courses/import",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = body
            },
            afterResponse: { res in status = res.status })
        return status
    }

    @Test func aRoundTripKeepsTheDeclaredType() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("testadmin_cbt", on: app)
            let course = try await typed(code: "TYPE_RT", type: .classActivity)
            let zipData = try await export(try course.requireID(), cookie: cookie)
            course.isArchived = true
            try await course.save(on: app.db)

            #expect(try await postImport(cookie: cookie, zipData: zipData) != .badRequest)
            let imported = try #require(
                try await APICourse.query(on: app.db).filter(\.$code == "TYPE_RT")
                    .filter(\.$isArchived == false).first())
            let assignment = try #require(
                try await APIAssignment.query(on: app.db)
                    .filter(\.$courseID == (try imported.requireID())).first())
            #expect(assignment.assignmentType == .classActivity)
        }
    }

    @Test func aCloneKeepsTheDeclaredType() async throws {
        try await withApp(app) { app in
            let course = try await typed(code: "TYPE_CLONE", type: .lab)
            let courseID = try course.requireID()
            let source = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$courseID == courseID).first())
            let sourceSetup = try #require(try await APITestSetup.find(source.testSetupID, on: app.db))

            let cloned = try await AssignmentAuthoringService.cloneAssignment(
                source: source, sourceSetup: sourceSetup, newTitle: "Pooled Testing (copy)",
                targetCourseID: courseID,
                directories: AuthoringDirectories(
                    setups: app.testSetupsDirectory, submissions: app.submissionsDirectory),
                on: app.db)

            #expect(cloned.assignment.assignmentType == .lab)
        }
    }
}
