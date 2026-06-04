// Tests for the course-section MCP tools — list_course_sections,
// create_course_section, and set_assignment_section (which mirrors the web
// dashboard's moveToSection, including the grading-mode sync). Backed by a real
// test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct CourseSectionToolsTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    private let manifest = """
        {"schemaVersion":1,"gradingMode":"browser","testSuites":[],"timeLimitSeconds":10}
        """

    /// Course + enrolled instructor + setup + assignment (ungrouped).
    private func fixture(on app: Application) async throws -> (course: APICourse, assignment: APIAssignment) {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_cs", courseID: courseID, manifest: manifest)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "setup_cs", courseID: courseID, title: "Lab 5")
        return (course, assignment)
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

    @Test func createCourseSectionPersists() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app)
            let out = try await CreateCourseSectionTool().execute(
                .init(courseCode: "CS246", name: "Labs", defaultGradingMode: "browser"), context(app))
            #expect(out.name == "Labs")
            #expect(out.defaultGradingMode == "browser")
            #expect(!out.sectionID.isEmpty)

            let saved = try #require(
                try await APICourseSection.find(UUID(uuidString: out.sectionID), on: app.db))
            #expect(saved.name == "Labs")
        }
    }

    @Test func createCourseSectionRejectsBadMode() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateCourseSectionTool().execute(
                    .init(courseCode: "CS246", name: "Labs", defaultGradingMode: "nonsense"), context(app))
            }
        }
    }

    @Test func listCourseSectionsReturnsInSortOrder() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let fx = try await fixture(on: app)
            let courseID = try fx.course.requireID()
            try await makeSection(on: app, name: "Exams", mode: "worker", order: 2, courseID: courseID)
            try await makeSection(on: app, name: "Labs", mode: "browser", order: 1, courseID: courseID)

            let out = try await ListCourseSectionsTool().execute(.init(courseCode: "CS246"), context(app))
            #expect(out.sections.map(\.name) == ["Labs", "Exams"])
            #expect(out.sections.first?.defaultGradingMode == "browser")
        }
    }

    @Test func setAssignmentSectionMovesAndSyncsGradingMode() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let fx = try await fixture(on: app)
            let courseID = try fx.course.requireID()
            // A "worker" section; the assignment's manifest starts "browser".
            let section = try await makeSection(
                on: app, name: "Labs", mode: "worker", order: 1, courseID: courseID)
            let sectionID = try section.requireID()

            let out = try await SetAssignmentSectionTool().execute(
                .init(assignmentPublicID: fx.assignment.publicID, courseSectionID: sectionID.uuidString),
                context(app))
            #expect(out.sectionID == sectionID.uuidString)
            #expect(out.sectionName == "Labs")
            #expect(out.gradingMode == "worker")

            // Assignment row now points at the section.
            let reloaded = try #require(try await APIAssignment.find(fx.assignment.id, on: app.db))
            #expect(reloaded.sectionID == sectionID)
            // The test setup adopted the section's grading mode.
            let setup = try #require(try await APITestSetup.find(fx.assignment.testSetupID, on: app.db))
            #expect(setup.decodedManifest()?.gradingMode.rawValue == "worker")
        }
    }

    @Test func setAssignmentSectionUngroups() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let fx = try await fixture(on: app)
            let courseID = try fx.course.requireID()
            let section = try await makeSection(
                on: app, name: "Labs", mode: "browser", order: 1, courseID: courseID)
            _ = try await SetAssignmentSectionTool().execute(
                .init(
                    assignmentPublicID: fx.assignment.publicID,
                    courseSectionID: try section.requireID().uuidString), context(app))

            let out = try await SetAssignmentSectionTool().execute(
                .init(assignmentPublicID: fx.assignment.publicID, courseSectionID: ""), context(app))
            #expect(out.sectionID.isEmpty)
            let reloaded = try #require(try await APIAssignment.find(fx.assignment.id, on: app.db))
            #expect(reloaded.sectionID == nil)
        }
    }

    @Test func setAssignmentSectionRejectsUnknownSection() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let fx = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetAssignmentSectionTool().execute(
                    .init(
                        assignmentPublicID: fx.assignment.publicID,
                        courseSectionID: UUID().uuidString), context(app))
            }
        }
    }

    @Test func setAssignmentSectionRejectsForeignSection() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let fx = try await fixture(on: app)
            // A section in a DIFFERENT course must not be assignable here.
            let other = try await makeTestCourse(on: app, code: "CS999", name: "Other")
            let foreign = try await makeSection(
                on: app, name: "Labs", mode: "browser", order: 1, courseID: try other.requireID())
            await #expect(throws: MCPToolError.self) {
                _ = try await SetAssignmentSectionTool().execute(
                    .init(
                        assignmentPublicID: fx.assignment.publicID,
                        courseSectionID: try foreign.requireID().uuidString), context(app))
            }
        }
    }
}
