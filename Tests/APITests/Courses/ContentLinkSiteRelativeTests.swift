// Tests/APITests/Courses/ContentLinkSiteRelativeTests.swift
//
// A content item link is http(s) or site-relative. A protocol-relative link
// (`//host`, or `/\host`, which browsers read the same way) links off the
// site, so the service refuses it on create and on update, and stores nothing.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) struct ContentLinkSiteRelativeTests {

    static let refused = [
        "//evil.example", "//evil.example/path", "/\\evil.example", "/\\\\evil.example",
        "javascript:alert(1)",
    ]

    static let accepted = ["/courses/x", "/", "https://example.org", "HTTP://example.org"]

    private func draft(url: String) throws(CourseContentError) -> ContentItemDraft {
        try ContentItemDraft(
            title: "Reading", kind: "link", links: [ContentLinkInput(label: "Open", url: url)],
            description: nil, updatedLabel: nil, isPublished: true)
    }

    private func createThroughService(
        url: String, courseID: UUID, on db: any Database
    ) async throws -> APICourseContentItem {
        try await CourseContentService.create(
            try draft(url: url), courseID: courseID, sectionID: nil, on: db)
    }

    @Test(arguments: refused)
    func aRefusedLinkCreatesNoItem(url: String) async throws {
        try await withTestApp { app in
            let courseID = try await makeTestCourse(on: app, code: "CLSR_CREATE").requireID()
            await #expect(throws: CourseContentError.unsafeLinkURL(url)) {
                _ = try await createThroughService(url: url, courseID: courseID, on: app.db)
            }
            let count = try await APICourseContentItem.query(on: app.db)
                .filter(\.$courseID == courseID).count()
            #expect(count == 0)
        }
    }

    @Test(arguments: refused)
    func aRefusedLinkLeavesTheStoredLinksUnchanged(url: String) async throws {
        try await withTestApp { app in
            let courseID = try await makeTestCourse(on: app, code: "CLSR_UPDATE").requireID()
            let item = try await createThroughService(
                url: "/courses/kept", courseID: courseID, on: app.db)
            await #expect(throws: CourseContentError.unsafeLinkURL(url)) {
                try await CourseContentService.update(
                    item, with: ContentItemEdit(links: [ContentLinkInput(label: "Open", url: url)]),
                    on: app.db)
            }
            let stored = try #require(try await APICourseContentItem.find(item.id, on: app.db))
            #expect(stored.links == [ContentLink(label: "Open", url: "/courses/kept")])
        }
    }

    @Test(arguments: accepted)
    func anAcceptedLinkIsStored(url: String) async throws {
        try await withTestApp { app in
            let courseID = try await makeTestCourse(on: app, code: "CLSR_ACCEPT").requireID()
            let item = try await createThroughService(url: url, courseID: courseID, on: app.db)
            let stored = try #require(try await APICourseContentItem.find(item.id, on: app.db))
            #expect(stored.links == [ContentLink(label: "Open", url: url)])
        }
    }
}
