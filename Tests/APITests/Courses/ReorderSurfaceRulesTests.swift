// Tests/APITests/Courses/ReorderSurfaceRulesTests.swift
//
// Every reorder surface follows the rules of `SortOrderRenumbering` (#2713):
// the four web routes and the four MCP tools admit a TA and refuse a student,
// and refuse a duplicate id, an unknown type, a partial section list and items
// of two sections. The service itself is pinned in `SortOrderRenumberingTests`.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class ReorderSurfaceRulesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-reorder-surface")
    }

    // MARK: - Fixtures

    private struct Fixture {
        let username: String
        let courseCode: String
        let sectionA: APICourseSection
        let sectionB: APICourseSection
        let labOne: APIAssignment
        let labTwo: APIAssignment
        let readingOne: APICourseContentItem
        let readingTwo: APICourseContentItem
    }

    private struct WebSession {
        let csrf: String
        let cookie: String
    }

    /// A `.closed` course with two sections. Section A holds two labs and
    /// section B two readings. `username` (a global student) is enrolled at
    /// `role`, so the course is the only, hence active, course.
    private func fixture(role: CourseRole, username: String = "reorder_user") async throws -> Fixture {
        let code = "REORDER"
        let course = try await makeTestCourse(on: app, code: code, mode: .closed)
        let courseID = try course.requireID()
        let sectionA = APICourseSection(name: "A", defaultGradingMode: "worker", sortOrder: 1, courseID: courseID)
        try await sectionA.save(on: app.db)
        let sectionB = APICourseSection(name: "B", defaultGradingMode: "worker", sortOrder: 2, courseID: courseID)
        try await sectionB.save(on: app.db)
        let labOne = try await lab("ro_one", courseID: courseID, section: sectionA, order: 1)
        let labTwo = try await lab("ro_two", courseID: courseID, section: sectionA, order: 2)
        let readingOne = try await reading("One", courseID: courseID, section: sectionB, order: 1)
        let readingTwo = try await reading("Two", courseID: courseID, section: sectionB, order: 2)
        let user = try await makeTestUser(on: app, username: username, role: "student")
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: role).save(on: app.db)
        return Fixture(
            username: username, courseCode: code, sectionA: sectionA, sectionB: sectionB,
            labOne: labOne, labTwo: labTwo, readingOne: readingOne, readingTwo: readingTwo)
    }

    private func lab(
        _ setupID: String, courseID: UUID, section: APICourseSection, order: Int
    ) async throws -> APIAssignment {
        try await makeTestSetup(on: app, id: setupID, courseID: courseID)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: setupID)
        assignment.sectionID = try section.requireID()
        assignment.sortOrder = order
        try await assignment.save(on: app.db)
        return assignment
    }

    private func reading(
        _ title: String, courseID: UUID, section: APICourseSection, order: Int
    ) async throws -> APICourseContentItem {
        let item = APICourseContentItem(
            courseID: courseID, sectionID: try section.requireID(), sortOrder: order, title: title,
            kind: .link, links: [ContentLink(label: "Site", url: "https://example.com")], isPublished: true)
        try await item.save(on: app.db)
        return item
    }

    private func session(_ fx: Fixture) async throws -> WebSession {
        let cookie = try await loginUser(username: fx.username, password: "pw", role: "student", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
        return WebSession(csrf: csrf, cookie: sessionCookie)
    }

    private func post(_ path: String, _ json: String, _ session: WebSession) async throws -> HTTPStatus {
        var status = HTTPStatus.internalServerError
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: session.cookie)
                req.headers.add(name: "x-csrf-token", value: session.csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: json)
            },
            afterResponse: { res in status = res.status })
        return status
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

    private func order(of section: APICourseSection) async throws -> Int {
        try #require(try await APICourseSection.find(section.id, on: app.db)).sortOrder
    }

    private func id(_ section: APICourseSection) throws -> String { try section.requireID().uuidString }

    private func id(_ item: APICourseContentItem) throws -> String { try item.requireID().uuidString }

    // MARK: - Web: role floor

    @Test func aTACanReorderEveryKindOnTheWeb() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(role: .ta)
            let web = try await session(fx)

            let sections = #"{"sectionIDs":["\#(try id(fx.sectionB))","\#(try id(fx.sectionA))"]}"#
            #expect(try await post("/instructor/sections/reorder", sections, web) == .ok)
            #expect(try await order(of: fx.sectionB) == 1)

            let labs = #"{"assignmentIDs":["\#(fx.labTwo.publicID)","\#(fx.labOne.publicID)"]}"#
            #expect(try await post("/instructor/reorder", labs, web) == .ok)
            #expect(try await order(of: fx.labTwo) == 1)

            let items = """
                {"items":[{"type":"assignment","id":"\(fx.labOne.publicID)"},\
                {"type":"assignment","id":"\(fx.labTwo.publicID)"}]}
                """
            #expect(try await post("/instructor/section-items/reorder", items, web) == .ok)
            #expect(try await order(of: fx.labOne) == 1)

            let readings = #"{"itemIDs":["\#(try id(fx.readingTwo))","\#(try id(fx.readingOne))"]}"#
            #expect(try await post("/instructor/content-items/reorder", readings, web) == .ok)
            #expect(try await order(of: fx.readingTwo) == 1)
        }
    }

    @Test func aStudentCannotReorderAnyKindOnTheWeb() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(role: .student)
            let web = try await session(fx)
            let requests = [
                (
                    "/instructor/sections/reorder",
                    #"{"sectionIDs":["\#(try id(fx.sectionB))","\#(try id(fx.sectionA))"]}"#
                ),
                ("/instructor/reorder", #"{"assignmentIDs":["\#(fx.labTwo.publicID)","\#(fx.labOne.publicID)"]}"#),
                (
                    "/instructor/section-items/reorder",
                    #"{"items":[{"type":"assignment","id":"\#(fx.labTwo.publicID)"}]}"#
                ),
                ("/instructor/content-items/reorder", #"{"itemIDs":["\#(try id(fx.readingTwo))"]}"#),
            ]
            for (path, json) in requests {
                let status = try await post(path, json, web)
                #expect(status == .forbidden || status == .seeOther, "\(path) admitted a student: \(status)")
            }
            #expect(try await order(of: fx.sectionB) == 2)
            #expect(try await order(of: fx.labTwo) == 2)
            #expect(try await order(of: fx.readingTwo) == 2)
        }
    }

    // MARK: - Web: duplicate, unknown type, subset, two sections

    @Test func everyWebRouteRefusesADuplicateID() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(role: .ta)
            let web = try await session(fx)
            let a = try id(fx.sectionA)
            let reading = try id(fx.readingOne)
            let lab = fx.labOne.publicID
            let requests = [
                ("/instructor/sections/reorder", #"{"sectionIDs":["\#(a)","\#(a)"]}"#),
                ("/instructor/reorder", #"{"assignmentIDs":["\#(lab)","\#(lab)"]}"#),
                (
                    "/instructor/section-items/reorder",
                    #"{"items":[{"type":"assignment","id":"\#(lab)"},{"type":"assignment","id":"\#(lab)"}]}"#
                ),
                ("/instructor/content-items/reorder", #"{"itemIDs":["\#(reading)","\#(reading)"]}"#),
            ]
            for (path, json) in requests {
                #expect(try await post(path, json, web) == .badRequest, "\(path) accepted a duplicate id")
            }
            #expect(try await order(of: fx.labOne) == 1)
        }
    }

    @Test func theSectionItemRouteRefusesAnUnknownType() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(role: .ta)
            let web = try await session(fx)
            let json = """
                {"items":[{"type":"assignment","id":"\(fx.labTwo.publicID)"},\
                {"type":"video","id":"x"},\
                {"type":"assignment","id":"\(fx.labOne.publicID)"}]}
                """
            #expect(try await post("/instructor/section-items/reorder", json, web) == .badRequest)
            #expect(try await order(of: fx.labTwo) == 2)
        }
    }

    @Test func theSectionRouteRefusesAPartialList() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(role: .ta)
            let web = try await session(fx)
            let json = #"{"sectionIDs":["\#(try id(fx.sectionB))"]}"#
            #expect(try await post("/instructor/sections/reorder", json, web) == .badRequest)
            #expect(try await order(of: fx.sectionB) == 2)
        }
    }

    @Test func theSectionItemRouteRefusesItemsOfTwoSections() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(role: .ta)
            let web = try await session(fx)
            let json = """
                {"items":[{"type":"content","id":"\(try id(fx.readingTwo))"},\
                {"type":"assignment","id":"\(fx.labOne.publicID)"}]}
                """
            #expect(try await post("/instructor/section-items/reorder", json, web) == .badRequest)
            #expect(try await order(of: fx.readingTwo) == 2)
        }
    }

    // MARK: - MCP: role floor

    @Test func aTACanReorderEveryKindThroughMCP() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(role: .ta)
            let ctx = context(fx)

            let sections = try await ReorderCourseSectionsTool().execute(
                .init(courseCode: fx.courseCode, orderedSectionIDs: [try id(fx.sectionB), try id(fx.sectionA)]), ctx)
            #expect(sections.sections.map(\.name) == ["B", "A"])

            let labs = try await ReorderAssignmentsTool().execute(
                .init(courseCode: fx.courseCode, orderedAssignmentPublicIDs: [fx.labTwo.publicID, fx.labOne.publicID]),
                ctx)
            #expect(labs.assignments.map(\.publicID) == [fx.labTwo.publicID, fx.labOne.publicID])

            let items = try await ReorderSectionItemsTool().execute(
                .init(
                    courseCode: fx.courseCode,
                    orderedItems: [
                        .init(type: "content", id: try id(fx.readingTwo)),
                        .init(type: "content", id: try id(fx.readingOne)),
                    ]),
                ctx)
            #expect(items.items.map(\.sortOrder) == [1, 2])

            let readings = try await ReorderContentItemsTool().execute(
                .init(
                    courseCode: fx.courseCode, orderedContentItemIDs: [try id(fx.readingOne), try id(fx.readingTwo)]),
                ctx)
            #expect(readings.contentItems.map(\.title) == ["One", "Two"])
        }
    }

    @Test func aStudentCannotReorderAnyKindThroughMCP() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(role: .student)
            let ctx = context(fx)
            await #expect(throws: MCPToolError.self) {
                _ = try await ReorderCourseSectionsTool().execute(
                    .init(
                        courseCode: fx.courseCode,
                        orderedSectionIDs: [try self.id(fx.sectionB), try self.id(fx.sectionA)]),
                    ctx)
            }
            await #expect(throws: MCPToolError.self) {
                _ = try await ReorderAssignmentsTool().execute(
                    .init(courseCode: fx.courseCode, orderedAssignmentPublicIDs: [fx.labTwo.publicID]), ctx)
            }
            await #expect(throws: MCPToolError.self) {
                _ = try await ReorderSectionItemsTool().execute(
                    .init(courseCode: fx.courseCode, orderedItems: [.init(type: "assignment", id: fx.labTwo.publicID)]),
                    ctx)
            }
            await #expect(throws: MCPToolError.self) {
                _ = try await ReorderContentItemsTool().execute(
                    .init(courseCode: fx.courseCode, orderedContentItemIDs: [try self.id(fx.readingTwo)]), ctx)
            }
            #expect(try await order(of: fx.sectionB) == 2)
            #expect(try await order(of: fx.labTwo) == 2)
            #expect(try await order(of: fx.readingTwo) == 2)
        }
    }

    // MARK: - MCP: duplicate and two sections

    @Test func everyMCPToolRefusesADuplicateID() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(role: .ta)
            let ctx = context(fx)
            let a = try id(fx.sectionA)
            let reading = try id(fx.readingOne)
            let lab = fx.labOne.publicID
            await #expect(throws: MCPToolError.self) {
                _ = try await ReorderCourseSectionsTool().execute(
                    .init(courseCode: fx.courseCode, orderedSectionIDs: [a, a]), ctx)
            }
            await #expect(throws: MCPToolError.self) {
                _ = try await ReorderAssignmentsTool().execute(
                    .init(courseCode: fx.courseCode, orderedAssignmentPublicIDs: [lab, lab]), ctx)
            }
            await #expect(throws: MCPToolError.self) {
                _ = try await ReorderSectionItemsTool().execute(
                    .init(
                        courseCode: fx.courseCode,
                        orderedItems: [.init(type: "assignment", id: lab), .init(type: "assignment", id: lab)]),
                    ctx)
            }
            await #expect(throws: MCPToolError.self) {
                _ = try await ReorderContentItemsTool().execute(
                    .init(courseCode: fx.courseCode, orderedContentItemIDs: [reading, reading]), ctx)
            }
        }
    }

    @Test func theMCPItemToolsRefuseItemsOfTwoSections() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(role: .ta)
            let ctx = context(fx)
            await #expect(throws: MCPToolError.self) {
                _ = try await ReorderSectionItemsTool().execute(
                    .init(
                        courseCode: fx.courseCode,
                        orderedItems: [
                            .init(type: "content", id: try self.id(fx.readingTwo)),
                            .init(type: "assignment", id: fx.labOne.publicID),
                        ]),
                    ctx)
            }
            #expect(try await order(of: fx.readingTwo) == 2)
        }
    }
}
