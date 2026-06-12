// Tests for the course-section management MCP tools — rename_course_section,
// delete_course_section, and reorder_course_sections. Backed by a real test
// database. (Creation + assignment live in CourseSectionToolsTests.)

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct CourseSectionManagementToolsTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    /// Course + enrolled instructor.
    @discardableResult
    private func fixture(on app: Application) async throws -> APICourse {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: course.requireID())
        return course
    }

    @discardableResult
    private func makeSection(
        on app: Application, name: String, mode: String, order: Int, courseID: UUID
    ) async throws -> APICourseSection {
        let section = APICourseSection(
            name: name, defaultGradingMode: mode, sortOrder: order, courseID: courseID)
        try await section.save(on: app.db)
        return section
    }

    @Test func renamesAndChangesGradingMode() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await fixture(on: app)
            let section = try await makeSection(
                on: app, name: "Labs", mode: "browser", order: 1, courseID: course.requireID())
            let out = try await RenameCourseSectionTool().execute(
                .init(
                    courseSectionID: section.requireID().uuidString, name: "Assignments",
                    defaultGradingMode: "worker"),
                context(app))
            #expect(out.name == "Assignments")
            #expect(out.defaultGradingMode == "worker")

            let saved = try #require(try await APICourseSection.find(section.id, on: app.db))
            #expect(saved.name == "Assignments")
            #expect(saved.defaultGradingMode == "worker")
        }
    }

    @Test func renameRequiresAtLeastOneField() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await fixture(on: app)
            let section = try await makeSection(
                on: app, name: "Labs", mode: "browser", order: 1, courseID: course.requireID())
            await #expect(throws: MCPToolError.self) {
                _ = try await RenameCourseSectionTool().execute(
                    .init(courseSectionID: section.requireID().uuidString, name: nil, defaultGradingMode: nil),
                    context(app))
            }
        }
    }

    @Test func deletesASectionAndUngroupsAssignments() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await fixture(on: app)
            let courseID = try course.requireID()
            let section = try await makeSection(
                on: app, name: "Labs", mode: "browser", order: 1, courseID: courseID)
            let sectionID = try section.requireID()
            try await makeTestSetup(on: app, id: "setup_csm", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_csm", courseID: courseID, title: "Lab")
            assignment.sectionID = sectionID
            try await assignment.save(on: app.db)

            let out = try await DeleteCourseSectionTool().execute(
                .init(courseSectionID: sectionID.uuidString), context(app))
            #expect(out.removed)
            #expect(out.ungroupedAssignmentCount == 1)

            #expect(try await APICourseSection.find(sectionID, on: app.db) == nil)
            let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(reloaded.sectionID == nil)
        }
    }

    @Test func deleteUnknownSectionIsIdempotent() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app)
            let out = try await DeleteCourseSectionTool().execute(
                .init(courseSectionID: UUID().uuidString), context(app))
            #expect(!out.removed)
            #expect(out.ungroupedAssignmentCount == 0)
        }
    }

    @Test func reordersSections() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await fixture(on: app)
            let courseID = try course.requireID()
            let a = try await makeSection(on: app, name: "A", mode: "browser", order: 1, courseID: courseID)
            let b = try await makeSection(on: app, name: "B", mode: "browser", order: 2, courseID: courseID)
            let c = try await makeSection(on: app, name: "C", mode: "browser", order: 3, courseID: courseID)

            let out = try await ReorderCourseSectionsTool().execute(
                .init(
                    courseCode: "CS246",
                    orderedSectionIDs: [
                        try c.requireID().uuidString, try a.requireID().uuidString,
                        try b.requireID().uuidString,
                    ]),
                context(app))
            #expect(out.sections.map(\.name) == ["C", "A", "B"])

            // Persisted order is reflected by list_course_sections.
            let listed = try await ListCourseSectionsTool().execute(.init(courseCode: "CS246"), context(app))
            #expect(listed.sections.map(\.name) == ["C", "A", "B"])
        }
    }

    @Test func reorderRejectsNonPermutation() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await fixture(on: app)
            let courseID = try course.requireID()
            let a = try await makeSection(on: app, name: "A", mode: "browser", order: 1, courseID: courseID)
            _ = try await makeSection(on: app, name: "B", mode: "browser", order: 2, courseID: courseID)
            await #expect(throws: MCPToolError.self) {
                _ = try await ReorderCourseSectionsTool().execute(
                    .init(courseCode: "CS246", orderedSectionIDs: [try a.requireID().uuidString]),
                    context(app))
            }
        }
    }

    @Test func deniesForeignCourseSection() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app)  // tester enrolled only in CS246
            let other = try await makeTestCourse(on: app, code: "CS999", name: "Other")
            let foreign = try await makeSection(
                on: app, name: "X", mode: "browser", order: 1, courseID: other.requireID())
            await #expect(throws: MCPToolError.self) {
                _ = try await RenameCourseSectionTool().execute(
                    .init(courseSectionID: foreign.requireID().uuidString, name: "Y", defaultGradingMode: nil),
                    context(app))
            }
        }
    }
}
