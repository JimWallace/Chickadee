// Tests/APITests/Assignments/ContentItemUnknownKindRouteTests.swift
//
// The web content-item form refuses an unknown kind, as MCP does (#2769).
// Before, the web stored it as a link without a word.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class ContentItemUnknownKindRouteTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-content-kind")
    }

    private struct FormBody: Content {
        var title: String
        var kind: String
        var isPublished: String
        var csrf: String
        enum CodingKeys: String, CodingKey {
            case title, kind, isPublished
            case csrf = "_csrf"
        }
    }

    private func instructorSession(_ username: String) async throws -> (token: String, cookie: String) {
        let cookie = try await loginUser(username: username, password: "pw", role: "instructor", on: app)
        try await promoteToInstructor(username, on: app)
        return try await csrfFields(for: "/instructor", cookie: cookie, on: app)
    }

    private func post(
        _ path: String, kind: String, title: String, session: (token: String, cookie: String)
    )
        async throws -> HTTPStatus
    {
        var status = HTTPStatus.internalServerError
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: session.cookie)
                try req.content.encode(
                    FormBody(title: title, kind: kind, isPublished: "true", csrf: session.token),
                    as: .urlEncodedForm)
            },
            afterResponse: { res in status = res.status })
        return status
    }

    @Test func createRefusesAnUnknownKind() async throws {
        try await withApp(app) { _ in
            let courseID = try await makeTestCourse(on: app, code: "CI_KIND_NEW", mode: .auto).requireID()
            let session = try await instructorSession("ci_kind_new")
            let status = try await post("/instructor/content-items", kind: "video", title: "Clip", session: session)
            #expect(status == .badRequest)
            #expect(
                try await APICourseContentItem.query(on: app.db).filter(\.$courseID == courseID).count() == 0)
        }
    }

    @Test func editRefusesAnUnknownKindAndKeepsTheItem() async throws {
        try await withApp(app) { _ in
            let courseID = try await makeTestCourse(on: app, code: "CI_KIND_EDIT", mode: .auto).requireID()
            let item = APICourseContentItem(
                courseID: courseID, sortOrder: 1, title: "Deck", kind: .slides, isPublished: true)
            try await item.save(on: app.db)
            let session = try await instructorSession("ci_kind_edit")
            let status = try await post(
                "/instructor/content-items/\(try item.requireID().uuidString)/edit", kind: "video",
                title: "Renamed", session: session)
            #expect(status == .badRequest)
            let stored = try #require(try await APICourseContentItem.find(item.id, on: app.db))
            #expect(stored.kind == .slides)
            #expect(stored.title == "Deck")
        }
    }
}
