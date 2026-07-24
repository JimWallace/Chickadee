// Tests/APITests/ContentAttachmentTests.swift
//
// Hosted file attachments on course content items (PR B): the storage helper's
// validation, the enrollment-gated download route, draft visibility, lifecycle
// deletion, and the MCP SSRF guard on URL-fetched attachments.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class ContentAttachmentTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-attach")
    }

    // MARK: - Helpers

    private func req() -> Request {
        Request(application: app, on: app.eventLoopGroup.any())
    }

    @discardableResult
    private func makeCourse(code: String) async throws -> APICourse {
        let course = APICourse(code: code, name: "Course \(code)", enrollmentMode: .auto)
        try await course.save(on: app.db)
        return course
    }

    /// Creates a content item and stores one attachment (bytes on disk +
    /// metadata on the item), returning both ids.
    private func makeItemWithAttachment(
        courseID: UUID, isPublished: Bool = true, name: String = "notes.pdf",
        bytes: Data = Data("hello pdf".utf8)
    ) async throws -> (item: APICourseContentItem, attachmentID: UUID) {
        let item = APICourseContentItem(
            courseID: courseID, sortOrder: 1, title: "Material", kind: .document,
            isPublished: isPublished)
        try await item.save(on: app.db)
        let itemID = try item.requireID()
        let attachment = try await ContentAttachmentStore.store(
            bytes: bytes, originalName: name, label: nil, sortOrder: 1, itemID: itemID, on: req())
        item.attachments = [attachment]
        try await item.save(on: app.db)
        return (item, attachment.id)
    }

    // MARK: - Store validation

    @Test func storeRejectsDisallowedType() async throws {
        try await withApp(app) { _ in
            #expect(throws: ContentAttachmentStore.StoreError.self) {
                _ = try ContentAttachmentStore.validate(
                    bytes: Data("x".utf8), originalName: "malware.exe")
            }
        }
    }

    @Test func storeRejectsUnsafeName() async throws {
        try await withApp(app) { _ in
            #expect(throws: ContentAttachmentStore.StoreError.self) {
                _ = try ContentAttachmentStore.validate(
                    bytes: Data("x".utf8), originalName: "../escape.pdf")
            }
        }
    }

    @Test func storeRejectsOversize() async throws {
        try await withApp(app) { _ in
            let tooBig = Data(count: ContentAttachmentStore.maxFileBytes + 1)
            #expect(throws: ContentAttachmentStore.StoreError.self) {
                _ = try ContentAttachmentStore.validate(bytes: tooBig, originalName: "big.pdf")
            }
        }
    }

    @Test func storeWritesFileAndMetadata() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "AT_STORE")
            let (item, attachmentID) = try await makeItemWithAttachment(
                courseID: try course.requireID(), name: "lecture.pdf")
            let itemID = try item.requireID()
            let path = ContentAttachmentStore.path(app, itemID: itemID, attachmentID: attachmentID)
            #expect(FileManager.default.fileExists(atPath: path))
            let reloaded = try #require(try await APICourseContentItem.find(itemID, on: app.db))
            #expect(reloaded.attachments.count == 1)
            #expect(reloaded.attachments.first?.originalName == "lecture.pdf")
        }
    }

    // MARK: - Gated serving

    @Test func enrolledStudentDownloadsAttachment() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "AT_SERVE")
            let (item, attachmentID) = try await makeItemWithAttachment(
                courseID: try course.requireID(), bytes: Data("PDF-BYTES".utf8))
            let itemID = try item.requireID()
            // Auto-enroll a student on login into the .auto course.
            let cookie = try await loginUser(username: "at_student", password: "pw", role: "student", on: app)

            try await app.asyncTest(
                .GET, "/content-files/\(itemID)/\(attachmentID)",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string == "PDF-BYTES")
                    #expect((res.headers.first(name: .contentDisposition) ?? "").contains("attachment"))
                })
        }
    }

    @Test func outsiderIsDeniedAttachment() async throws {
        try await withApp(app) { _ in
            // The item's course is CLOSED so a stranger isn't auto-enrolled.
            let course = APICourse(code: "AT_OUT", name: "Closed", enrollmentMode: .closed)
            try await course.save(on: app.db)
            let (item, attachmentID) = try await makeItemWithAttachment(courseID: try course.requireID())
            let itemID = try item.requireID()
            let cookie = try await loginUser(username: "at_outsider", password: "pw", role: "student", on: app)

            try await app.asyncTest(
                .GET, "/content-files/\(itemID)/\(attachmentID)",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .forbidden || res.status == .notFound)
                })
        }
    }

    @Test func draftAttachmentHiddenFromStudentButVisibleToStaff() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "AT_DRAFT")
            let courseID = try course.requireID()
            let (item, attachmentID) = try await makeItemWithAttachment(
                courseID: courseID, isPublished: false)
            let itemID = try item.requireID()
            let path = "/content-files/\(itemID)/\(attachmentID)"

            let studentCookie = try await loginUser(
                username: "at_draft_student", password: "pw", role: "student", on: app)
            try await app.asyncTest(
                .GET, path,
                beforeRequest: { req in req.headers.add(name: .cookie, value: studentCookie) },
                afterResponse: { res in #expect(res.status == .notFound) })

            let staffCookie = try await loginUser(
                username: "at_draft_staff", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("at_draft_staff", on: app)
            try await app.asyncTest(
                .GET, path,
                beforeRequest: { req in req.headers.add(name: .cookie, value: staffCookie) },
                afterResponse: { res in #expect(res.status == .ok) })
        }
    }

    // MARK: - Lifecycle

    @Test func deletingItemRemovesAttachmentFiles() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "AT_DELETE")
            let (item, attachmentID) = try await makeItemWithAttachment(courseID: try course.requireID())
            let itemID = try item.requireID()
            let path = ContentAttachmentStore.path(app, itemID: itemID, attachmentID: attachmentID)
            #expect(FileManager.default.fileExists(atPath: path))

            ContentAttachmentStore.removeDirectory(app, itemID: itemID)
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }

    // MARK: - MCP SSRF guard

    @Test func mcpAttachRejectsPrivateAddress() async throws {
        try await withApp(app) { app in
            let course = try await makeCourse(code: "AT_MCP")
            let courseID = try course.requireID()
            let tester = try await makeTestUser(on: app, username: "at_mcp", role: "instructor")
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
            let context = ToolContext(
                request: req(), subject: "at_mcp", grantedScopes: [.write])

            // A loopback URL is refused by the SSRF guard before any fetch.
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateContentItemTool().execute(
                    .init(
                        courseCode: "AT_MCP", title: "Doc", kind: "document", links: nil,
                        attachments: [.init(label: nil, sourceUrl: "https://127.0.0.1/secret.pdf")],
                        description: nil, updatedLabel: nil, courseSectionID: nil, isPublished: nil),
                    context)
            }
        }
    }
}
