// Tests/APITests/SectionItemInterleaveTests.swift
//
// Unified interleave (PR A): assignments and ungraded content items share one
// per-section `sort_order` sequence, so a reading can sit between two labs.
// Covers the merged dashboard order, the unified reorder endpoint
// (POST /instructor/section-items/reorder) across both tables, the cross-section
// move append, and the reorder_section_items MCP tool.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class SectionItemInterleaveTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-interleave")
    }

    // MARK: - Helpers

    @discardableResult
    private func makeCourse(code: String) async throws -> APICourse {
        let course = APICourse(code: code, name: "Course \(code)", enrollmentMode: .auto)
        try await course.save(on: app.db)
        return course
    }

    @discardableResult
    private func makeSection(name: String, order: Int, courseID: UUID) async throws -> APICourseSection {
        let section = APICourseSection(
            name: name, defaultGradingMode: "worker", sortOrder: order, courseID: courseID)
        try await section.save(on: app.db)
        return section
    }

    @discardableResult
    private func makeContentItem(
        title: String, courseID: UUID, sectionID: UUID?, order: Int
    ) async throws -> APICourseContentItem {
        let item = APICourseContentItem(
            courseID: courseID, sectionID: sectionID, sortOrder: order, title: title,
            kind: .notebook, links: [ContentLink(label: "Site", url: "https://example.com")],
            isPublished: true)
        try await item.save(on: app.db)
        return item
    }

    @discardableResult
    private func makeAssignmentInSection(
        setupID: String, title: String, courseID: UUID, sectionID: UUID?, order: Int?
    ) async throws -> APIAssignment {
        try await makeTestSetup(on: app, id: setupID, courseID: courseID)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: title)
        assignment.sectionID = sectionID
        assignment.sortOrder = order
        try await assignment.save(on: app.db)
        return assignment
    }

    private func staffCookie(_ username: String) async throws -> String {
        let cookie = try await loginUser(username: username, password: "pw", role: "instructor", on: app)
        try await promoteToInstructor(username, on: app)
        return cookie
    }

    /// Offset of `needle` in `haystack`, or a large sentinel when absent so an
    /// order assertion fails loudly rather than silently comparing nils.
    private func offset(of needle: String, in haystack: String) -> Int {
        guard let range = haystack.range(of: needle) else { return Int.max }
        return haystack.distance(from: haystack.startIndex, to: range.lowerBound)
    }

    // MARK: - Merged order

    @Test func instructorDashboardInterleavesContentBetweenAssignments() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "IL_ORDER")
            let courseID = try course.requireID()
            let section = try await makeSection(name: "Week 1", order: 1, courseID: courseID)
            let sectionID = try section.requireID()
            // Shared per-section sequence: lab(1), reading(2), lab(3).
            try await makeAssignmentInSection(
                setupID: "il_a", title: "AlphaLab", courseID: courseID, sectionID: sectionID, order: 1)
            try await makeContentItem(
                title: "MidReading", courseID: courseID, sectionID: sectionID, order: 2)
            try await makeAssignmentInSection(
                setupID: "il_b", title: "BetaLab", courseID: courseID, sectionID: sectionID, order: 3)

            let cookie = try await staffCookie("il_instr")
            try await app.asyncTest(
                .GET, "/instructor",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    let a = self.offset(of: "AlphaLab", in: body)
                    let mid = self.offset(of: "MidReading", in: body)
                    let b = self.offset(of: "BetaLab", in: body)
                    // The reading renders between the two labs, not in a lane above.
                    #expect(a < mid, "AlphaLab should precede MidReading")
                    #expect(mid < b, "MidReading should sit between the two labs")
                })
        }
    }

    // MARK: - Unified reorder endpoint

    @Test func unifiedReorderRenumbersAcrossBothTables() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "IL_REORDER")
            let courseID = try course.requireID()
            let section = try await makeSection(name: "Labs", order: 1, courseID: courseID)
            let sectionID = try section.requireID()
            let assignment = try await makeAssignmentInSection(
                setupID: "ir_a", title: "Lab", courseID: courseID, sectionID: sectionID, order: 1)
            let content = try await makeContentItem(
                title: "Reading", courseID: courseID, sectionID: sectionID, order: 2)

            let cookie = try await staffCookie("ir_instr")
            let (token, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            // Reverse the order: content first, then the assignment.
            let contentID = try content.requireID().uuidString
            let payload = """
                {"sectionID":"\(sectionID.uuidString)","items":[\
                {"type":"content","id":"\(contentID)"},\
                {"type":"assignment","id":"\(assignment.publicID)"}]}
                """
            try await app.asyncTest(
                .POST, "/instructor/section-items/reorder",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: token)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: payload)
                },
                afterResponse: { res in #expect(res.status == .ok) })

            let reloadedContent = try #require(try await APICourseContentItem.find(content.id, on: app.db))
            let reloadedAssignment = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(reloadedContent.sortOrder == 1)
            #expect(reloadedAssignment.sortOrder == 2)
        }
    }

    @Test func unifiedReorderDeniedForStudent() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "IL_AUTHZ")
            let courseID = try course.requireID()
            let content = try await makeContentItem(
                title: "Reading", courseID: courseID, sectionID: nil, order: 1)

            // A plain student is not staff of the active course.
            let cookie = try await loginUser(username: "il_student", password: "pw", role: "student", on: app)
            let (token, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
            let contentID = try content.requireID().uuidString
            let payload = """
                {"sectionID":"","items":[{"type":"content","id":"\(contentID)"}]}
                """
            try await app.asyncTest(
                .POST, "/instructor/section-items/reorder",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: token)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: payload)
                },
                afterResponse: { res in
                    // The /instructor area gate denies (403), or redirects a
                    // non-staff caller — either way it must not be a 200 write.
                    #expect(res.status == .forbidden || res.status == .seeOther)
                })
            // The order was not changed.
            let reloaded = try #require(try await APICourseContentItem.find(content.id, on: app.db))
            #expect(reloaded.sortOrder == 1)
        }
    }

    // MARK: - Cross-section move appends to the destination lane

    @Test func movingAssignmentAppendsToDestinationLane() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "IL_MOVE")
            let courseID = try course.requireID()
            let source = try await makeSection(name: "Source", order: 1, courseID: courseID)
            let dest = try await makeSection(name: "Dest", order: 2, courseID: courseID)
            let destID = try dest.requireID()
            // Destination already holds a content item at order 5 — the moved
            // assignment must append AFTER it (max across both tables + 1).
            try await makeContentItem(title: "DestReading", courseID: courseID, sectionID: destID, order: 5)
            let assignment = try await makeAssignmentInSection(
                setupID: "mv_a", title: "Mover", courseID: courseID,
                sectionID: try source.requireID(), order: 1)

            let cookie = try await staffCookie("mv_instr")
            let (token, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/instructor/\(assignment.publicID)/section",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: token)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: "{\"sectionID\":\"\(destID.uuidString)\"}")
                },
                afterResponse: { res in #expect(res.status == .ok) })

            let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(reloaded.sectionID == destID)
            #expect(reloaded.sortOrder == 6)  // appended after the content item at 5
        }
    }

    // MARK: - MCP reorder_section_items

    @Test func mcpReorderSectionItemsRenumbersBoth() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "IL_MCP")
            let courseID = try course.requireID()
            let section = try await makeSection(name: "Labs", order: 1, courseID: courseID)
            let sectionID = try section.requireID()
            let assignment = try await makeAssignmentInSection(
                setupID: "mcp_a", title: "Lab", courseID: courseID, sectionID: sectionID, order: 1)
            let content = try await makeContentItem(
                title: "Reading", courseID: courseID, sectionID: sectionID, order: 2)

            // The MCP account must be enrolled to act on the course.
            let tester = try await makeTestUser(on: app, username: "mcp_tester", role: "instructor")
            try await makeTestEnrollment(
                on: app, userID: tester.requireID(), courseID: courseID)
            let context = ToolContext(
                request: Request(application: app, on: app.eventLoopGroup.any()),
                subject: "mcp_tester", grantedScopes: [.write])

            let out = try await ReorderSectionItemsTool().execute(
                .init(
                    courseCode: "IL_MCP",
                    orderedItems: [
                        .init(type: "content", id: try content.requireID().uuidString),
                        .init(type: "assignment", id: assignment.publicID),
                    ]),
                context)
            #expect(out.items.map(\.type) == ["content", "assignment"])
            #expect(out.items.map(\.sortOrder) == [1, 2])

            let reloadedContent = try #require(try await APICourseContentItem.find(content.id, on: app.db))
            let reloadedAssignment = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(reloadedContent.sortOrder == 1)
            #expect(reloadedAssignment.sortOrder == 2)
        }
    }
}
