// Tests/APITests/Assignments/ContentItemMultipleAttachmentTests.swift
//
// Several files chosen in the content item form's file input. The form posts
// one multipart part per file, all with the name of the input. Vapor decodes
// repeated parts as an array only when the name ends in `[]`.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class ContentItemMultipleAttachmentTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-multi-attach")
    }

    /// Logs in an instructor of a new course and returns a session cookie and
    /// its CSRF token.
    private func instructorSession(
        code: String, username: String
    ) async throws -> (
        courseID: UUID, token: String, cookie: String
    ) {
        let course = try await makeTestCourse(on: app, code: code, mode: .auto)
        let cookie = try await loginUser(username: username, password: "pw", role: "instructor", on: app)
        try await promoteToInstructor(username, on: app)
        let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        return (try course.requireID(), token, newCookie)
    }

    /// Posts the create form with one file part per entry of `files`, each
    /// part named `partName`, and returns the stored attachment names.
    private func createItem(
        title: String, partName: String, files: [(name: String, bytes: String)],
        courseID: UUID, token: String, cookie: String
    ) async throws -> [String] {
        let res = try await postMultipartForm(
            "/instructor/content-items", cookie: cookie,
            fields: [
                ("_csrf", token), ("title", title), ("kind", "document"),
                ("isPublished", "true"),
            ],
            files: files.map { (partName, $0.name, "application/pdf", Data($0.bytes.utf8)) },
            on: app)
        #expect(res.status == .seeOther)
        let item = try #require(
            try await APICourseContentItem.query(on: app.db)
                .filter(\.$courseID == courseID).filter(\.$title == title).first())
        return item.attachments.sorted { $0.sortOrder < $1.sortOrder }.map(\.originalName)
    }

    /// The defect: parts that share a bare name decode as one file, so the
    /// last file wins. This is why the form must not send a bare name.
    @Test func bareNameKeepsOnlyTheLastFile() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession(code: "MA_BARE", username: "ma_bare")
            let names = try await createItem(
                title: "Bare", partName: "attachmentFiles",
                files: [("first.pdf", "one"), ("second.pdf", "two")],
                courseID: session.courseID, token: session.token, cookie: session.cookie)
            #expect(names == ["second.pdf"])
        }
    }

    /// Both file inputs, on the add-material form and on an item's edit form,
    /// carry the array name, so the browser never sends the bare name above.
    @Test func formsNameTheFileInputAsAnArray() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession(code: "MA_FORM", username: "ma_form")
            let item = APICourseContentItem(
                courseID: session.courseID, sortOrder: 1, title: "Existing", kind: .document)
            try await item.save(on: app.db)
            var html = ""
            try await app.asyncTest(
                .GET, "/instructor",
                beforeRequest: { req in req.headers.add(name: .cookie, value: session.cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    html = res.body.string
                })
            let itemID = try item.requireID()
            #expect(html.contains("action=\"/instructor/content-items\""))
            #expect(html.contains("action=\"/instructor/content-items/\(itemID)/edit\""))
            #expect(html.components(separatedBy: "name=\"attachmentFiles[]\"").count - 1 == 2)
            #expect(!html.contains("name=\"attachmentFiles\""))
        }
    }

    /// Two parts named `attachmentFiles[]`, as the form now sends them, store
    /// two attachments in the order chosen.
    @Test func arrayNameStoresEveryFileInOrder() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession(code: "MA_ARRAY", username: "ma_array")
            let names = try await createItem(
                title: "Array", partName: "attachmentFiles[]",
                files: [("first.pdf", "one"), ("second.pdf", "two")],
                courseID: session.courseID, token: session.token, cookie: session.cookie)
            #expect(names == ["first.pdf", "second.pdf"])
        }
    }

    /// One part named `attachmentFiles[]` (a single selection) still decodes,
    /// through the array or the single-file path of `MultipartFileList`.
    @Test func arrayNameWithOneFileStoresIt() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession(code: "MA_ONE", username: "ma_one")
            let names = try await createItem(
                title: "One", partName: "attachmentFiles[]", files: [("only.pdf", "one")],
                courseID: session.courseID, token: session.token, cookie: session.cookie)
            #expect(names == ["only.pdf"])
        }
    }

    /// The edit form appends every chosen file after the existing attachments.
    @Test func editAppendsEveryFileInOrder() async throws {
        try await withApp(app) { _ in
            let session = try await instructorSession(code: "MA_EDIT", username: "ma_edit")
            _ = try await createItem(
                title: "Edit", partName: "attachmentFiles[]", files: [("first.pdf", "one")],
                courseID: session.courseID, token: session.token, cookie: session.cookie)
            let item = try #require(
                try await APICourseContentItem.query(on: app.db)
                    .filter(\.$courseID == session.courseID).filter(\.$title == "Edit").first())
            let itemID = try item.requireID()
            let boundary = "Boundary-Multi-Attach-Edit"
            try await app.asyncTest(
                .POST, "/instructor/content-items/\(itemID)/edit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: session.cookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                    req.body = .init(
                        buffer: arMultipartBody(
                            boundary: boundary,
                            fields: [
                                ("_csrf", session.token), ("title", "Edit"), ("kind", "document"),
                                ("isPublished", "true"),
                            ],
                            files: [
                                ("attachmentFiles[]", "second.pdf", "application/pdf", Data("two".utf8)),
                                ("attachmentFiles[]", "third.pdf", "application/pdf", Data("three".utf8)),
                            ]))
                },
                afterResponse: { res in #expect(res.status == .seeOther) })
            let reloaded = try #require(try await APICourseContentItem.find(itemID, on: app.db))
            let names = reloaded.attachments.sorted { $0.sortOrder < $1.sortOrder }.map(\.originalName)
            #expect(names == ["first.pdf", "second.pdf", "third.pdf"])
        }
    }
}
