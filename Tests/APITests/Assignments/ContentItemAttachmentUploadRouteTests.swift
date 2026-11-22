// Tests/APITests/Assignments/ContentItemAttachmentUploadRouteTests.swift
//
// The web content-item handlers (CourseAdminRoutes+ContentItems) on paths that
// ContentItemRoutesTests does not walk: a multipart upload of hosted
// attachments (stored, refused by type, empty part ignored), a malformed or
// unknown item or attachment id, the URL rule on an edit, and the course scope
// of a write (an instructor of one course cannot edit another course's item).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class ContentItemAttachmentUploadRouteTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-content-upload")
    }

    // MARK: - Helpers

    /// One part of a multipart body: a plain field, or a file when
    /// `filename` is set.
    private struct Part {
        let name: String
        let value: Data
        var filename: String?
    }

    private static func field(_ name: String, _ value: String) -> Part {
        Part(name: name, value: Data(value.utf8))
    }

    private static func multipartBody(_ parts: [Part], boundary: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: 1024)
        for part in parts {
            buffer.writeString("--\(boundary)\r\n")
            if let filename = part.filename {
                buffer.writeString(
                    "Content-Disposition: form-data; name=\"\(part.name)\"; filename=\"\(filename)\"\r\n")
                buffer.writeString("Content-Type: application/octet-stream\r\n\r\n")
            } else {
                buffer.writeString("Content-Disposition: form-data; name=\"\(part.name)\"\r\n\r\n")
            }
            buffer.writeBytes(part.value)
            buffer.writeString("\r\n")
        }
        buffer.writeString("--\(boundary)--\r\n")
        return buffer
    }

    /// An instructor of a new `.auto` course with an active course and a
    /// fresh CSRF token. Returns the course id, the token and the cookie.
    private func instructorSession(
        code: String, username: String
    ) async throws -> (courseID: UUID, token: String, cookie: String) {
        let course = try await makeTestCourse(on: app, code: code, mode: .auto)
        let cookie = try await loginUser(username: username, password: "pw", role: "instructor", on: app)
        try await promoteToInstructor(username, on: app)
        let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        return (try course.requireID(), token, newCookie)
    }

    private func makeItem(courseID: UUID, title: String = "Reading") async throws -> APICourseContentItem {
        let item = APICourseContentItem(
            courseID: courseID, sectionID: nil, sortOrder: 1, title: title,
            kind: .link, links: [ContentLink(label: "Site", url: "https://example.com")],
            isPublished: true)
        try await item.save(on: app.db)
        return item
    }

    private func postMultipart(
        _ path: String, parts: [Part], cookie: String
    ) async throws -> HTTPStatus {
        let boundary = "content-upload-\(UUID().uuidString)"
        var status = HTTPStatus.internalServerError
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = .init(buffer: Self.multipartBody(parts, boundary: boundary))
            },
            afterResponse: { res in status = res.status })
        return status
    }

    private func postForm(_ path: String, fields: [String: String], cookie: String) async throws -> HTTPStatus {
        var status = HTTPStatus.internalServerError
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                try req.content.encode(fields, as: .urlEncodedForm)
            },
            afterResponse: { res in status = res.status })
        return status
    }

    private func editParts(token: String, url: String = "https://example.com") -> [Part] {
        [
            Self.field("_csrf", token), Self.field("title", "Reading"), Self.field("kind", "link"),
            Self.field("linkLabels[]", "Site"), Self.field("linkURLs[]", url),
            Self.field("isPublished", "true"),
        ]
    }

    // MARK: - Upload on create

    @Test func createStoresAnUploadedAttachmentOnTheItemAndOnDisk() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession(code: "CIU_CREATE", username: "ciu_create")
            let pdf = Data("%PDF-1.4 reading\n".utf8)
            let status = try await postMultipart(
                "/instructor/content-items",
                parts: [
                    Self.field("_csrf", session.token), Self.field("title", "Week 1 notes"),
                    Self.field("kind", "document"), Self.field("isPublished", "true"),
                    Part(name: "attachmentFiles", value: pdf, filename: "notes.pdf"),
                ],
                cookie: session.cookie)
            #expect(status == .seeOther)

            let item = try #require(
                try await APICourseContentItem.query(on: app.db)
                    .filter(\.$courseID == session.courseID).first())
            let itemID = try item.requireID()
            #expect(item.title == "Week 1 notes")
            #expect(item.attachments.count == 1)
            let attachment = try #require(item.attachments.first)
            #expect(attachment.originalName == "notes.pdf")
            #expect(attachment.sizeBytes == pdf.count)
            #expect(attachment.sortOrder == 1)
            let onDisk = ContentAttachmentStore.path(app, itemID: itemID, attachmentID: attachment.id)
            #expect(FileManager.default.contents(atPath: onDisk) == pdf)
        }
    }

    /// A create with a refused file returns 400 and keeps no item: the
    /// uploads are checked before the item is saved (#3214).
    @Test func aCreateWithARefusedFileKeepsNoItem() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession(code: "CIU_CREATE_BAD", username: "ciu_create_bad")
            let status = try await postMultipart(
                "/instructor/content-items",
                parts: [
                    Self.field("_csrf", session.token), Self.field("title", "Week 2 notes"),
                    Self.field("kind", "document"), Self.field("isPublished", "true"),
                    Part(name: "attachmentFiles[]", value: Data("ok".utf8), filename: "ok.txt"),
                    Part(name: "attachmentFiles[]", value: Data("MZ".utf8), filename: "setup.exe"),
                ],
                cookie: session.cookie)
            #expect(status == .badRequest)

            let items = try await APICourseContentItem.query(on: app.db)
                .filter(\.$courseID == session.courseID).all()
            #expect(items.isEmpty)
        }
    }

    // MARK: - Upload on edit

    @Test func editAppendsAfterTheExistingAttachments() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession(code: "CIU_APPEND", username: "ciu_append")
            let item = try await makeItem(courseID: session.courseID)
            let existing = ContentAttachment(
                id: UUID(), originalName: "old.txt", sizeBytes: 3, sortOrder: 4, label: nil)
            item.attachments = [existing]
            try await item.save(on: app.db)
            let itemID = try item.requireID()

            // Two files as the repeated `File[]` shape. A part named without
            // the brackets decodes to the last file only (see the PR body).
            let status = try await postMultipart(
                "/instructor/content-items/\(itemID.uuidString)/edit",
                parts: editParts(token: session.token) + [
                    Part(name: "attachmentFiles[]", value: Data("a,b\n1,2\n".utf8), filename: "data.csv"),
                    Part(name: "attachmentFiles[]", value: Data("# Notes\n".utf8), filename: "notes.md"),
                ],
                cookie: session.cookie)
            #expect(status == .seeOther)

            let reloaded = try #require(try await APICourseContentItem.find(itemID, on: app.db))
            #expect(reloaded.attachments.map(\.originalName) == ["old.txt", "data.csv", "notes.md"])
            #expect(reloaded.attachments.map(\.sortOrder) == [4, 5, 6])
        }
    }

    @Test func aDisallowedFileTypeIsRefusedAndNothingIsWritten() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession(code: "CIU_TYPE", username: "ciu_type")
            let item = try await makeItem(courseID: session.courseID)
            let itemID = try item.requireID()

            // One good file and one bad one: the whole batch is checked first.
            let status = try await postMultipart(
                "/instructor/content-items/\(itemID.uuidString)/edit",
                parts: editParts(token: session.token) + [
                    Part(name: "attachmentFiles[]", value: Data("ok".utf8), filename: "ok.txt"),
                    Part(name: "attachmentFiles[]", value: Data("MZ".utf8), filename: "setup.exe"),
                ],
                cookie: session.cookie)
            #expect(status == .badRequest)

            let reloaded = try #require(try await APICourseContentItem.find(itemID, on: app.db))
            #expect(reloaded.attachments.isEmpty)
            let directory = ContentAttachmentStore.directory(app, itemID: itemID)
            #expect(!FileManager.default.fileExists(atPath: directory))
        }
    }

    @Test func anEmptyFilePartIsIgnored() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession(code: "CIU_EMPTY", username: "ciu_empty")
            let item = try await makeItem(courseID: session.courseID)
            let itemID = try item.requireID()

            // An untouched file input posts a part with no bytes.
            let status = try await postMultipart(
                "/instructor/content-items/\(itemID.uuidString)/edit",
                parts: editParts(token: session.token) + [
                    Part(name: "attachmentFiles", value: Data(), filename: "")
                ],
                cookie: session.cookie)
            #expect(status == .seeOther)

            let reloaded = try #require(try await APICourseContentItem.find(itemID, on: app.db))
            #expect(reloaded.attachments.isEmpty)
        }
    }

    // MARK: - URL rule on edit

    @Test(arguments: ["javascript:alert(1)", "data:text/html,x", "mailto:a@example.com", "ftp://example.com/f"])
    func editRefusesALinkThatIsNotHTTPOrSiteRelative(url: String) async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession(code: "CIU_URL", username: "ciu_url")
            let item = try await makeItem(courseID: session.courseID)
            let itemID = try item.requireID()

            let status = try await postMultipart(
                "/instructor/content-items/\(itemID.uuidString)/edit",
                parts: editParts(token: session.token, url: url), cookie: session.cookie)
            #expect(status == .badRequest)

            let reloaded = try #require(try await APICourseContentItem.find(itemID, on: app.db))
            #expect(reloaded.links.map(\.url) == ["https://example.com"])
        }
    }

    // MARK: - Malformed and unknown ids

    @Test func aMalformedOrUnknownItemIDIsNotFound() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession(code: "CIU_ID", username: "ciu_id")
            let form = ["_csrf": session.token]
            for id in ["not-a-uuid", UUID().uuidString] {
                #expect(
                    try await postForm("/instructor/content-items/\(id)/delete", fields: form, cookie: session.cookie)
                        == .notFound)
                #expect(
                    try await postForm(
                        "/instructor/content-items/\(id)/visibility",
                        fields: form.merging(["isPublished": "false"]) { $1 }, cookie: session.cookie)
                        == .notFound)
            }
        }
    }

    @Test func aMalformedAttachmentIDIsNotFoundAndKeepsTheAttachments() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession(code: "CIU_ATT", username: "ciu_att")
            let item = try await makeItem(courseID: session.courseID)
            let attachment = ContentAttachment(
                id: UUID(), originalName: "keep.pdf", sizeBytes: 1, sortOrder: 1, label: nil)
            item.attachments = [attachment]
            try await item.save(on: app.db)
            let itemID = try item.requireID()

            let status = try await postForm(
                "/instructor/content-items/\(itemID.uuidString)/attachments/not-a-uuid/delete",
                fields: ["_csrf": session.token], cookie: session.cookie)
            #expect(status == .notFound)

            let reloaded = try #require(try await APICourseContentItem.find(itemID, on: app.db))
            #expect(reloaded.attachments.map(\.id) == [attachment.id])
        }
    }

    // MARK: - Course scope

    @Test func anInstructorCannotEditAnotherCoursesItem() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession(code: "CIU_MINE", username: "ciu_mine")
            let other = try await makeTestCourse(on: app, code: "CIU_THEIRS", name: "Other")
            let foreign = try await makeItem(courseID: try other.requireID(), title: "Theirs")
            let foreignID = try foreign.requireID()

            let edit = try await postMultipart(
                "/instructor/content-items/\(foreignID.uuidString)/edit",
                parts: editParts(token: session.token), cookie: session.cookie)
            #expect(edit == .forbidden || edit == .notFound)
            let delete = try await postForm(
                "/instructor/content-items/\(foreignID.uuidString)/delete",
                fields: ["_csrf": session.token], cookie: session.cookie)
            #expect(delete == .forbidden || delete == .notFound)

            let reloaded = try #require(try await APICourseContentItem.find(foreignID, on: app.db))
            #expect(reloaded.title == "Theirs")
        }
    }
}
