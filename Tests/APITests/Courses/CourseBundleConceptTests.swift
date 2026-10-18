// Tests/APITests/Courses/CourseBundleConceptTests.swift
//
// A course bundle keeps an assignment's lab concept through export and import
// (docs/student-wardrobe.md, "Concept rings"), and a value this instance does
// not know as a concept travels as no concept.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class CourseBundleConceptTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-cbconcept")
    }

    private static let workerManifestJSON =
        TestManifests.workerEmptyExplicit
    private static let dummyZipBytes: [UInt8] = [0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)

    /// A course with one assignment tagged with `concept`.
    private func tagged(code: String, concept: AssignmentConcept?) async throws -> APICourse {
        let course = APICourse(code: code, name: "Concept Bundle Course")
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        let setupID = "setup_\(code.lowercased())"
        let zipPath = app.testSetupsDirectory + "\(setupID).zip"
        try Data(Self.dummyZipBytes).write(to: URL(fileURLWithPath: zipPath))
        try await APITestSetup(id: setupID, manifest: Self.workerManifestJSON, zipPath: zipPath, courseID: courseID)
            .save(on: app.db)
        let assignment = APIAssignment(
            testSetupID: setupID, title: "Loops Lab", dueAt: nil, isOpen: true, courseID: courseID)
        assignment.concept = concept
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
        let boundary = "cbc-boundary-\(UUID().uuidString)"
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

    /// The assignment of the active (imported) course with `code`.
    private func importedAssignment(code: String) async throws -> APIAssignment {
        let course = try #require(
            try await APICourse.query(on: app.db).filter(\.$code == code).filter(\.$isArchived == false).first())
        return try #require(
            try await APIAssignment.query(on: app.db).filter(\.$courseID == (try course.requireID())).first())
    }

    private func archive(_ course: APICourse) async throws {
        course.isArchived = true
        try await course.save(on: app.db)
    }

    @Test func aRoundTripKeepsTheConcept() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("testadmin_cbc", on: app)
            let course = try await tagged(code: "CONCEPT_RT", concept: .loops)
            let zipData = try await export(try course.requireID(), cookie: cookie)
            try await archive(course)

            #expect(try await postImport(cookie: cookie, zipData: zipData) != .badRequest)
            #expect(try await importedAssignment(code: "CONCEPT_RT").concept == .loops)
        }
    }

    @Test func aRoundTripKeepsNoConcept() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("testadmin_cbc", on: app)
            let course = try await tagged(code: "CONCEPT_NONE", concept: nil)
            let zipData = try await export(try course.requireID(), cookie: cookie)
            try await archive(course)

            #expect(try await postImport(cookie: cookie, zipData: zipData) != .badRequest)
            #expect(try await importedAssignment(code: "CONCEPT_NONE").concept == nil)
        }
    }

    /// A stored value this instance does not know is not a concept: the export
    /// leaves it out, so it arrives as no concept, and the rest of the bundle
    /// imports. (An unknown value inside a bundle from a newer instance is
    /// covered by `BundledAssignmentConceptTests`.)
    @Test func anUnknownStoredConceptTravelsAsNone() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("testadmin_cbc", on: app)
            let course = try await tagged(code: "CONCEPT_UNKNOWN", concept: nil)
            let assignment = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$courseID == (try course.requireID())).first())
            assignment.conceptRaw = "recursion"
            try await assignment.save(on: app.db)
            let zipData = try await export(try course.requireID(), cookie: cookie)
            try await archive(course)

            #expect(try await postImport(cookie: cookie, zipData: zipData) != .badRequest)
            let imported = try await importedAssignment(code: "CONCEPT_UNKNOWN")
            #expect(imported.title == "Loops Lab")
            #expect(imported.conceptRaw == nil)
        }
    }
}
