// Tests that every MCP result naming a course says WHICH offering it is
// (docs/course-terms.md). Course codes are unique per term, so a bare code can
// name two active courses; a read then takes the newest term. Echoing the
// bare code back hid that choice from the agent. These tests pin `courseKey`
// and `courseTerm` on each course-reporting tool, and the course key in the
// manifest resource names.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class MCPCourseTermOutputTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-mcp-term-output")
    }

    private let fall26 = AcademicTerm(year: 2026, season: .fall)
    private let winter27 = AcademicTerm(year: 2027, season: .winter)

    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "prof", grantedScopes: [.read, .write])
    }

    private struct Offerings {
        let older: APICourse
        let newer: APICourse
        let olderAssignment: APIAssignment
    }

    /// Two active CS246 offerings (Fall 2026 and Winter 2027), both taught by
    /// "prof", with one assignment in the older offering.
    private func twoOfferings(on app: Application) async throws -> Offerings {
        let older = APICourse(code: "CS246", name: "OOP", term: fall26)
        try await older.save(on: app.db)
        let newer = APICourse(code: "CS246", name: "OOP", term: winter27)
        try await newer.save(on: app.db)
        let prof = try await makeTestUser(on: app, username: "prof", role: "instructor")
        try await makeTestEnrollment(on: app, userID: prof.requireID(), courseID: older.requireID())
        try await makeTestEnrollment(on: app, userID: prof.requireID(), courseID: newer.requireID())
        try await makeTestSetup(on: app, id: "setup_f26", courseID: older.requireID())
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "setup_f26", courseID: older.requireID(), title: "Lab 1")
        return Offerings(older: older, newer: newer, olderAssignment: assignment)
    }

    private func fields(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let fields)? = value else { return nil }
        return fields
    }

    // MARK: - Reads

    @Test func aBareCodeReadReportsTheOfferingItResolvedTo() async throws {
        try await withApp(app) { app in
            _ = try await twoOfferings(on: app)
            let output = try await ListAssignmentsTool().execute(
                ListAssignmentsTool.Input(courseCode: "CS246"), context(app))
            #expect(output.courseCode == "CS246")
            #expect(output.courseKey == "CS246-W27")
            #expect(output.courseTerm == "Winter 2027")
            #expect(output.assignments.isEmpty)
        }
    }

    @Test func aKeyedReadReportsTheCodeAndTheKey() async throws {
        try await withApp(app) { app in
            _ = try await twoOfferings(on: app)
            let output = try await ListAssignmentsTool().execute(
                ListAssignmentsTool.Input(courseCode: "CS246-F26"), context(app))
            #expect(output.courseCode == "CS246")
            #expect(output.courseKey == "CS246-F26")
            #expect(output.courseTerm == "Fall 2026")
            #expect(output.assignments.map(\.title) == ["Lab 1"])
        }
    }

    @Test func aCourseWithNoTermReportsItsCodeAsTheKey() async throws {
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS100")
            let prof = try await makeTestUser(on: app, username: "prof", role: "instructor")
            try await makeTestEnrollment(on: app, userID: prof.requireID(), courseID: course.requireID())

            let output = try await ListAssignmentsTool().execute(
                ListAssignmentsTool.Input(courseCode: "CS100"), context(app))
            #expect(output.courseKey == "CS100")
            #expect(output.courseTerm == nil)

            // A nil term is omitted, which the output schema allows.
            let encoded = try JSONValue(encoding: output)
            #expect(fields(encoded)?["courseTerm"] == nil)
            #expect(fields(encoded)?["courseKey"] == .string("CS100"))
        }
    }

    @Test func getAssignmentReportsItsOwnOffering() async throws {
        try await withApp(app) { app in
            let offerings = try await twoOfferings(on: app)
            let output = try await GetAssignmentTool().execute(
                GetAssignmentTool.Input(assignmentPublicID: offerings.olderAssignment.publicID),
                context(app))
            #expect(output.courseCode == "CS246")
            #expect(output.courseKey == "CS246-F26")
            #expect(output.courseTerm == "Fall 2026")
        }
    }

    @Test func courseSectionAndContentListsReportTheOffering() async throws {
        try await withApp(app) { app in
            _ = try await twoOfferings(on: app)
            let sections = try await ListCourseSectionsTool().execute(
                ListCourseSectionsTool.Input(courseCode: "CS246-F26"), context(app))
            #expect(sections.courseKey == "CS246-F26")
            #expect(sections.courseTerm == "Fall 2026")

            let items = try await ListContentItemsTool().execute(
                ListContentItemsTool.Input(courseCode: "CS246"), context(app))
            #expect(items.courseKey == "CS246-W27")
            #expect(items.courseTerm == "Winter 2027")
        }
    }

    // MARK: - Writes

    @Test func writesThroughAKeyReportTheOfferingTheyChanged() async throws {
        try await withApp(app) { app in
            let offerings = try await twoOfferings(on: app)

            let section = try await CreateCourseSectionTool().execute(
                CreateCourseSectionTool.Input(
                    courseCode: "CS246-F26", name: "Labs", defaultGradingMode: nil),
                context(app))
            #expect(section.courseCode == "CS246")
            #expect(section.courseKey == "CS246-F26")
            #expect(section.courseTerm == "Fall 2026")

            let reorderedSections = try await ReorderCourseSectionsTool().execute(
                ReorderCourseSectionsTool.Input(
                    courseCode: "CS246-F26", orderedSectionIDs: [section.sectionID]),
                context(app))
            #expect(reorderedSections.courseKey == "CS246-F26")

            let reordered = try await ReorderAssignmentsTool().execute(
                ReorderAssignmentsTool.Input(
                    courseCode: "CS246-F26",
                    orderedAssignmentPublicIDs: [offerings.olderAssignment.publicID]),
                context(app))
            #expect(reordered.courseKey == "CS246-F26")
            #expect(reordered.courseTerm == "Fall 2026")

            let interleaved = try await ReorderSectionItemsTool().execute(
                ReorderSectionItemsTool.Input(
                    courseCode: "CS246-F26",
                    orderedItems: [.init(type: "assignment", id: offerings.olderAssignment.publicID)]),
                context(app))
            #expect(interleaved.courseKey == "CS246-F26")

            let content = try await ReorderContentItemsTool().execute(
                ReorderContentItemsTool.Input(courseCode: "CS246-W27", orderedContentItemIDs: []),
                context(app))
            #expect(content.courseKey == "CS246-W27")
            #expect(content.courseTerm == "Winter 2027")
        }
    }

    @Test func createAssignmentReportsTheResolvedCourseNotTheArgument() async throws {
        try await withApp(app) { app in
            _ = try await twoOfferings(on: app)
            let notebook = try JSONDecoder().decode(
                JSONValue.self, from: Data(#"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#.utf8))
            let output = try await CreateAssignmentTool().execute(
                CreateAssignmentTool.Input(
                    courseCode: "CS246-W27", title: "Lab 2", notebook: notebook, language: "python"),
                context(app))
            #expect(output.courseCode == "CS246")
            #expect(output.courseKey == "CS246-W27")
            #expect(output.courseTerm == "Winter 2027")
        }
    }

    @Test func cloneAssignmentReportsTheTargetOffering() async throws {
        try await withApp(app) { app in
            let offerings = try await twoOfferings(on: app)

            let intoNewTerm = try await CloneAssignmentTool().execute(
                CloneAssignmentTool.Input(
                    sourceAssignmentPublicID: offerings.olderAssignment.publicID,
                    newTitle: "Lab 1", targetCourseCode: "CS246-W27"),
                context(app))
            #expect(intoNewTerm.courseCode == "CS246")
            #expect(intoNewTerm.courseKey == "CS246-W27")
            #expect(intoNewTerm.courseTerm == "Winter 2027")

            // With no target, the clone stays in the source's own offering.
            let inPlace = try await CloneAssignmentTool().execute(
                CloneAssignmentTool.Input(
                    sourceAssignmentPublicID: offerings.olderAssignment.publicID,
                    newTitle: "Lab 1 (Copy)", targetCourseCode: nil),
                context(app))
            #expect(inPlace.courseKey == "CS246-F26")
            #expect(inPlace.courseTerm == "Fall 2026")
        }
    }

    // MARK: - Resources

    @Test func manifestResourceNamesCarryTheCourseKey() async throws {
        try await withApp(app) { app in
            let offerings = try await twoOfferings(on: app)
            let result = try await MCPResourceProvider().list(context: context(app))
            guard case .array(let resources)? = fields(result)?["resources"] else {
                throw IssueRecorded("resources/list returned no resources array")
            }
            let uri = MCPResourceProvider.manifestURI(publicID: offerings.olderAssignment.publicID)
            let entry = try #require(resources.first { fields($0)?["uri"] == .string(uri) })
            #expect(fields(entry)?["name"] == .string("CS246-F26 — Lab 1 (test suite manifest)"))
        }
    }
}
