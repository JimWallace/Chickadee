// Tests/APITests/MCP/ContentItemToolRefusalTests.swift
//
// The content-item MCP tools (CourseContentItemTools.swift) on paths that
// CourseContentItemToolsTests does not walk: the link-URL rule on an update
// (http(s) or site-relative only), a malformed or unknown item id, the course
// scope of the MCP account on update and delete, attachment metadata in the
// output, and an attachment source URL that the SSRF guard refuses before any
// network call.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) struct ContentItemToolRefusalTests {

    /// An item in the MCP account's course "CS246".
    private func seedItem(on app: Application) async throws -> APICourseContentItem {
        let course = try await seedMCPCourse(on: app)
        let item = APICourseContentItem(
            courseID: try course.requireID(), sectionID: nil, sortOrder: 1, title: "Reading",
            kind: .link, links: [ContentLink(label: "Site", url: "https://example.com")],
            isPublished: true)
        try await item.save(on: app.db)
        return item
    }

    /// An item in a course the MCP account is not enrolled in.
    private func seedForeignItem(on app: Application) async throws -> APICourseContentItem {
        let other = try await makeTestCourse(on: app, code: "CS999", name: "Other")
        let item = APICourseContentItem(
            courseID: try other.requireID(), sectionID: nil, sortOrder: 1, title: "Theirs",
            kind: .link, links: [], isPublished: true)
        try await item.save(on: app.db)
        return item
    }

    private func update(
        _ id: String, links: [ContentLinkInput]? = nil, title: String? = nil,
        attachments: [ContentAttachmentInput]? = nil, on app: Application
    ) async throws -> ContentItemDTO {
        try await UpdateContentItemTool().execute(
            .init(
                contentItemID: id, title: title, kind: nil, links: links, attachments: attachments,
                description: nil, updatedLabel: nil, isPublished: nil, courseSectionID: nil),
            mcpContext(app))
    }

    private static func invalidArgumentsDetail(_ error: any Error) -> String? {
        if case .invalidArguments(let detail) = error as? MCPToolError { return detail }
        return nil
    }

    // MARK: - Link URL rule

    @Test(
        arguments: [
            "javascript:alert(1)", "JavaScript:alert(1)", "data:text/html,x", "vbscript:x",
            "mailto:a@example.com", "ftp://example.com/f", "example.com/page",
        ])
    func updateRefusesALinkThatIsNotHTTPOrSiteRelative(url: String) async throws {
        try await withTestApp { app in
            let item = try await seedItem(on: app)
            let id = try item.requireID()
            let error = await #expect(throws: MCPToolError.self) {
                _ = try await update(id.uuidString, links: [.init(label: "x", url: url)], on: app)
            }
            let detail = try #require(error.flatMap(Self.invalidArgumentsDetail))
            #expect(detail.contains(url))
            let reloaded = try #require(try await APICourseContentItem.find(id, on: app.db))
            #expect(reloaded.links.map(\.url) == ["https://example.com"])
        }
    }

    @Test func updateAcceptsHTTPHTTPSAndSiteRelativeLinks() async throws {
        try await withTestApp { app in
            let item = try await seedItem(on: app)
            let urls = ["http://example.com/a", "HTTPS://example.com/b", "/materials/c.ipynb", "  https://x.test/d  "]
            let out = try await update(
                try item.requireID().uuidString, links: urls.map { .init(label: "L", url: $0) }, on: app)
            #expect(
                out.links.map(\.url) == [
                    "http://example.com/a", "HTTPS://example.com/b", "/materials/c.ipynb", "https://x.test/d",
                ])
        }
    }

    // MARK: - Malformed and unknown ids

    @Test func updateRefusesAMalformedOrUnknownID() async throws {
        try await withTestApp { app in
            _ = try await seedItem(on: app)
            for id in [" not-a-uuid ", UUID().uuidString] {
                let error = await #expect(throws: MCPToolError.self) {
                    _ = try await update(id, title: "Renamed", on: app)
                }
                let detail = try #require(error.flatMap(Self.invalidArgumentsDetail))
                #expect(detail.contains(id.trimmingCharacters(in: .whitespaces)))
            }
        }
    }

    @Test func deleteRefusesAMalformedID() async throws {
        try await withTestApp { app in
            let item = try await seedItem(on: app)
            let error = await #expect(throws: MCPToolError.self) {
                _ = try await DeleteContentItemTool().execute(.init(contentItemID: "nope"), mcpContext(app))
            }
            #expect(error.flatMap(Self.invalidArgumentsDetail) != nil)
            #expect(try await APICourseContentItem.find(item.id, on: app.db) != nil)
        }
    }

    // MARK: - Course scope of the MCP account

    @Test func updateOfAnItemInAnUnenrolledCourseIsRefusedAndChangesNothing() async throws {
        try await withTestApp { app in
            _ = try await seedItem(on: app)
            let foreign = try await seedForeignItem(on: app)
            let id = try foreign.requireID()
            await #expect(throws: MCPToolError.self) {
                _ = try await update(id.uuidString, title: "Hijacked", on: app)
            }
            let reloaded = try #require(try await APICourseContentItem.find(id, on: app.db))
            #expect(reloaded.title == "Theirs")
        }
    }

    @Test func deleteOfAnItemInAnUnenrolledCourseAnswersAsUnknownAndKeepsIt() async throws {
        try await withTestApp { app in
            _ = try await seedItem(on: app)
            let foreign = try await seedForeignItem(on: app)
            let id = try foreign.requireID()
            let out = try await DeleteContentItemTool().execute(
                .init(contentItemID: id.uuidString), mcpContext(app))
            #expect(out.removed == false)
            #expect(try await APICourseContentItem.find(id, on: app.db) != nil)
        }
    }

    // MARK: - Attachments

    @Test func theOutputCarriesEachAttachmentWithItsGatedDownloadPath() async throws {
        try await withTestApp { app in
            let item = try await seedItem(on: app)
            let itemID = try item.requireID()
            let attachment = ContentAttachment(
                id: UUID(), originalName: "syllabus.pdf", sizeBytes: 1234, sortOrder: 1, label: "Syllabus")
            item.attachments = [attachment]
            try await item.save(on: app.db)

            let listed = try await ListContentItemsTool().execute(.init(courseCode: "CS246"), mcpContext(app))
            let dto = try #require(listed.contentItems.first?.attachments.first)
            #expect(dto.attachmentID == attachment.id.uuidString)
            #expect(dto.originalName == "syllabus.pdf")
            #expect(dto.sizeBytes == 1234)
            #expect(dto.label == "Syllabus")
            #expect(dto.downloadPath == "/content-files/\(itemID.uuidString)/\(attachment.id.uuidString)")
        }
    }

    /// Each URL is refused by `SupportFileURLFetcher.validate` or by the
    /// blocked-address check on an IP literal, so no request leaves the host.
    @Test(
        arguments: [
            "http://example.com/a.pdf", "https://user:pw@example.com/a.pdf", "https://127.0.0.1/a.pdf",
            "https://169.254.169.254/latest/meta-data", "https://[::1]/a.pdf",
        ])
    func anAttachmentSourceURLTheGuardRefusesStoresNothing(sourceUrl: String) async throws {
        try await withTestApp { app in
            let item = try await seedItem(on: app)
            let itemID = try item.requireID()
            let error = await #expect(throws: MCPToolError.self) {
                _ = try await update(
                    itemID.uuidString, attachments: [.init(label: nil, sourceUrl: sourceUrl)], on: app)
            }
            #expect(error.flatMap(Self.invalidArgumentsDetail) != nil)
            let reloaded = try #require(try await APICourseContentItem.find(itemID, on: app.db))
            #expect(reloaded.attachments.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: ContentAttachmentStore.directory(app, itemID: itemID)))
        }
    }
}
