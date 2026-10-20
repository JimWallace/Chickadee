// Tests/APITests/Courses/SectionItemFullListTests.swift
//
// A section-item reorder names every item of its section (#2713).
// Assignments and content items share one per-section `sort_order` sequence,
// so a partial list would leave two items at the same position. The rule is
// held by `SortOrderRenumbering.renumberSectionItems`; these tests pin it on
// the service, on a web route and on each MCP item tool.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class SectionItemFullListTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-section-full-list")
    }

    // MARK: - Fixtures

    private struct Fixture {
        let username: String
        let courseCode: String
        let courseID: UUID
        let section: APICourseSection
        let labOne: APIAssignment
        let labTwo: APIAssignment
        let reading: APICourseContentItem
    }

    /// A `.closed` course with one section that holds two labs (order 1, 2)
    /// and a reading (order 3). `username` (a global student) is a TA there.
    private func fixture() async throws -> Fixture {
        let code = "FULLLIST"
        let course = try await makeTestCourse(on: app, code: code, mode: .closed)
        let courseID = try course.requireID()
        let section = APICourseSection(name: "A", defaultGradingMode: "worker", sortOrder: 1, courseID: courseID)
        try await section.save(on: app.db)
        let labOne = try await lab("fl_one", courseID: courseID, sectionID: try section.requireID(), order: 1)
        let labTwo = try await lab("fl_two", courseID: courseID, sectionID: try section.requireID(), order: 2)
        let reading = APICourseContentItem(
            courseID: courseID, sectionID: try section.requireID(), sortOrder: 3, title: "Reading",
            kind: .link, links: [ContentLink(label: "Site", url: "https://example.com")], isPublished: true)
        try await reading.save(on: app.db)
        let username = "full_list_ta"
        let user = try await makeTestUser(on: app, username: username, role: "student")
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: .ta).save(on: app.db)
        return Fixture(
            username: username, courseCode: code, courseID: courseID, section: section,
            labOne: labOne, labTwo: labTwo, reading: reading)
    }

    private func lab(_ setupID: String, courseID: UUID, sectionID: UUID?, order: Int?) async throws -> APIAssignment {
        try await makeTestSetup(on: app, id: setupID, courseID: courseID)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: setupID)
        assignment.sectionID = sectionID
        assignment.sortOrder = order
        try await assignment.save(on: app.db)
        return assignment
    }

    private func context(_ fx: Fixture) -> ToolContext {
        ToolContext(request: makeTestRequest(on: app), subject: fx.username, grantedScopes: [.write])
    }

    private func order(of assignment: APIAssignment) async throws -> Int? {
        try #require(try await APIAssignment.find(assignment.id, on: app.db)).sortOrder
    }

    private func order(of item: APICourseContentItem) async throws -> Int {
        try #require(try await APICourseContentItem.find(item.id, on: app.db)).sortOrder
    }

    // MARK: - Service

    @Test func thePartOfASectionIsRefused() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            await #expect(throws: ReorderError.incompleteSection(expected: 3)) {
                _ = try await SortOrderRenumbering.renumberSectionItems(
                    [.assignment(publicID: fx.labTwo.publicID), .assignment(publicID: fx.labOne.publicID)],
                    inCourse: fx.courseID, on: app.db)
            }
            #expect(try await order(of: fx.labTwo) == 2)
            #expect(try await order(of: fx.labOne) == 1)
        }
    }

    @Test func theWholeSectionIsRenumbered() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            _ = try await SortOrderRenumbering.renumberSectionItems(
                [
                    .assignment(publicID: fx.labTwo.publicID),
                    .content(try fx.reading.requireID()),
                    .assignment(publicID: fx.labOne.publicID),
                ],
                inCourse: fx.courseID, on: app.db)
            #expect(try await order(of: fx.labTwo) == 1)
            #expect(try await order(of: fx.reading) == 2)
            #expect(try await order(of: fx.labOne) == 3)
        }
    }

    @Test func thePartOfTheUngroupedItemsIsRefused() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let first = try await lab("fl_u1", courseID: fx.courseID, sectionID: nil, order: nil)
            _ = try await lab("fl_u2", courseID: fx.courseID, sectionID: nil, order: nil)
            await #expect(throws: ReorderError.incompleteSection(expected: 2)) {
                _ = try await SortOrderRenumbering.renumberSectionItems(
                    [.assignment(publicID: first.publicID)], inCourse: fx.courseID, on: app.db)
            }
            #expect(try await order(of: first) == nil)
        }
    }

    // MARK: - Web

    @Test func theWebAssignmentRouteRefusesASectionThatAlsoHoldsContent() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let cookie = try await loginUser(username: fx.username, password: "pw", role: "student", on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
            let json = #"{"assignmentIDs":["\#(fx.labTwo.publicID)","\#(fx.labOne.publicID)"]}"#
            try await app.asyncTest(
                .POST, "/instructor/reorder",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: json)
                },
                afterResponse: { res in #expect(res.status == .badRequest) })
            #expect(try await order(of: fx.labTwo) == 2)
        }
    }

    // MARK: - MCP

    @Test func eachMCPItemToolRefusesAPartialSection() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let ctx = context(fx)
            await #expect(throws: MCPToolError.self) {
                _ = try await ReorderSectionItemsTool().execute(
                    .init(courseCode: fx.courseCode, orderedItems: [.init(type: "assignment", id: fx.labTwo.publicID)]),
                    ctx)
            }
            await #expect(throws: MCPToolError.self) {
                _ = try await ReorderAssignmentsTool().execute(
                    .init(
                        courseCode: fx.courseCode, orderedAssignmentPublicIDs: [fx.labTwo.publicID, fx.labOne.publicID]),
                    ctx)
            }
            await #expect(throws: MCPToolError.self) {
                _ = try await ReorderContentItemsTool().execute(
                    .init(courseCode: fx.courseCode, orderedContentItemIDs: [try fx.reading.requireID().uuidString]),
                    ctx)
            }
            #expect(try await order(of: fx.labTwo) == 2)
            #expect(try await order(of: fx.reading) == 3)
        }
    }
}
