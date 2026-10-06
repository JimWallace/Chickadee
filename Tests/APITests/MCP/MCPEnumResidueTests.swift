// Tests/APITests/MCP/MCPEnumResidueTests.swift
//
// The last hand-typed MCP enums are derived from their types, and
// create_content_item refuses an unknown kind instead of storing a link (#2337).

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct MCPEnumResidueTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester", grantedScopes: [.read, .write])
    }

    private func fixture(on app: Application) async throws {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: course.requireID())
    }

    private func create(kind: String?, _ app: Application) async throws -> CreateContentItemTool.Output {
        try await CreateContentItemTool().execute(
            .init(
                courseCode: "CS246", title: "Item", kind: kind, links: nil, description: nil,
                updatedLabel: nil, courseSectionID: nil, isPublished: nil),
            context(app))
    }

    @Test func createRefusesAnUnknownKindAndNamesTheLegalOnes() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            try await fixture(on: app)
            await #expect(
                throws: MCPToolError.invalidArguments(
                    detail: "kind must be one of: \(MCPEnumProse<ContentItemKind>.oneOfList).")
            ) {
                _ = try await create(kind: "video", app)
            }
            #expect(try await APICourseContentItem.query(on: app.db).count() == 0)
        }
    }

    @Test func createWithoutAKindStillMakesALink() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            try await fixture(on: app)
            let out = try await create(kind: nil, app)
            let id = try #require(UUID(uuidString: out.contentItemID))
            let item = try #require(try await APICourseContentItem.find(id, on: app.db))
            #expect(item.kind == .link)
        }
    }

    @Test func achievementSchemaEnumsListEveryCase() throws {
        let text = try #require(String(bytes: try JSONEncoder().encode(achievementRowSchema), encoding: .utf8))
        for token in MCPEnumProse<AchievementScope>.tokens + MCPEnumProse<ConditionComparator>.tokens {
            #expect(text.contains("\"\(token)\""))
        }
    }

    @Test func reorderSectionItemsRefusesAnUnknownItemType() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await ReorderSectionItemsTool().execute(
                    .init(courseCode: "CS246", orderedItems: [.init(type: "video", id: "x")]),
                    context(app))
            }
        }
    }
}
