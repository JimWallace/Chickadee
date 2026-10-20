// The enrollment contract for every content tool (#2716): an agent never
// reaches a course that its account is not enrolled in. Each tool in
// `MCPToolCatalog.live` runs twice on the same sample input: once as an
// account enrolled in the course, once as an account that is staff in another
// course but not in this one. The first run must not be refused for
// authorization, so the refusal in the second run comes from the missing
// enrollment and not from the input.
//
// A third run acts as a student who is enrolled in the course. Students may
// not use the MCP interface at all, so every tool refuses that account.
//
// A new tool fails `everyToolHasASample` until it gets a sample here.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.timeLimit(.minutes(10)))
struct MCPEnrollmentDenialContractTests {
    /// What the unenrolled account gets back from a tool.
    enum Denial: Sendable {
        /// `MCPToolError.notAuthorized`.
        case notAuthorized
        /// The same answer as for an id that does not exist (#2342).
        case answersAsUnknownID
        /// A list that leaves the course out.
        case omitsCourse
        /// The tool reads no course.
        case notCourseScoped
    }

    struct Sample: Sendable {
        /// The arguments, with `$A` for the assignment public ID, `$S` for the
        /// course-section id, `$C` for the content-item id and `$NB` for a
        /// small notebook.
        let arguments: String
        let denial: Denial

        init(_ arguments: String, _ denial: Denial = .notAuthorized) {
            self.arguments = arguments
            self.denial = denial
        }
    }

    /// The seeded ids the samples refer to.
    struct World {
        let courseID: UUID
        let assignmentPublicID: String
        let sectionID: UUID
        let contentItemID: UUID
    }

    static let courseCode = "CS246"
    static let unknownID = "00000000-0000-4000-8000-000000000000"

    static let samples: [String: Sample] = [
        "list_courses": Sample("{}", .omitsCourse),
        "get_server_info": Sample("{}", .notCourseScoped),
        "list_assignments": Sample(#"{"courseCode":"CS246"}"#),
        "list_course_sections": Sample(#"{"courseCode":"CS246"}"#),
        "get_assignment": Sample(#"{"assignmentPublicID":"$A"}"#),
        "get_suite": Sample(#"{"assignmentPublicID":"$A"}"#),
        "get_notebook": Sample(#"{"assignmentPublicID":"$A"}"#),
        "get_solution": Sample(#"{"assignmentPublicID":"$A"}"#),
        "get_support_files": Sample(#"{"assignmentPublicID":"$A"}"#),
        "get_global_inputs": Sample(#"{"assignmentPublicID":"$A"}"#),
        "get_achievements": Sample(#"{"assignmentPublicID":"$A"}"#),
        "preview_personalization": Sample(#"{"assignmentPublicID":"$A"}"#),
        "validate_assignment": Sample(#"{"assignmentPublicID":"$A","timeoutSeconds":1}"#),
        "get_validation_result": Sample(#"{"assignmentPublicID":"$A"}"#),
        "run_validation": Sample(#"{"assignmentPublicID":"$A","timeoutSeconds":1}"#),
        "list_assignment_versions": Sample(#"{"assignmentPublicID":"$A"}"#),
        "get_assignment_version": Sample(#"{"assignmentPublicID":"$A","version":1}"#),
        "restore_assignment_version": Sample(#"{"assignmentPublicID":"$A","version":1}"#),
        "update_assignment": Sample(#"{"assignmentPublicID":"$A","title":"Renamed"}"#),
        "set_grading_mode": Sample(#"{"assignmentPublicID":"$A","gradingMode":"worker"}"#),
        "set_submission_mode": Sample(#"{"assignmentPublicID":"$A","submissionMode":"uploadOnly"}"#),
        "set_assignment_language": Sample(#"{"assignmentPublicID":"$A","language":"python"}"#),
        "set_assignment_concept": Sample(#"{"assignmentPublicID":"$A","concept":"loops"}"#),
        "set_time_limit": Sample(#"{"assignmentPublicID":"$A","seconds":30}"#),
        "set_dataset": Sample(#"{"assignmentPublicID":"$A","filename":"cases.csv","sampleSize":1}"#),
        "list_datasets": Sample(#"{"courseCode":"CS246"}"#),
        "get_dataset": Sample(#"{"courseCode":"CS246","slug":"ward-cases"}"#),
        "create_dataset": Sample(
            #"{"courseCode":"CS246","name":"Clinic visits","assignmentPublicID":"$A","filename":"cases.csv"}"#),
        "update_dataset": Sample(#"{"courseCode":"CS246","slug":"ward-cases","name":"Renamed"}"#),
        // A loopback URL, so the enrolled run stops at the SSRF guard and
        // never reaches the network.
        "add_dataset_version": Sample(
            #"{"courseCode":"CS246","slug":"ward-cases","sourceUrl":"http://127.0.0.1/cases.csv"}"#),
        "attach_dataset": Sample(#"{"assignmentPublicID":"$A","slug":"ward-cases"}"#),
        "detach_dataset": Sample(#"{"assignmentPublicID":"$A","filename":"cases.csv"}"#),
        "set_minimum_runner_version": Sample(#"{"assignmentPublicID":"$A","minimumRunnerVersion":"0.5.0"}"#),
        "set_activity": Sample(#"{"assignmentPublicID":"$A","kind":"bestMetric"}"#),
        "run_tournament": Sample(#"{"assignmentPublicID":"$A"}"#),
        "update_suite": Sample(#"{"assignmentPublicID":"$A","edits":[{"script":"test_a.sh","points":2}]}"#),
        "update_global_inputs": Sample(#"{"assignmentPublicID":"$A","variables":[]}"#),
        "update_achievements": Sample(#"{"assignmentPublicID":"$A","achievements":[]}"#),
        "get_course_achievements": Sample(#"{"courseCode":"CS246"}"#),
        "update_course_achievements": Sample(#"{"courseCode":"CS246","achievements":[]}"#),
        "update_section_variables": Sample(#"{"assignmentPublicID":"$A","sectionID":"part1","variables":[]}"#),
        "create_suite_section": Sample(#"{"assignmentPublicID":"$A","name":"Part 1"}"#),
        "rename_suite_section": Sample(#"{"assignmentPublicID":"$A","sectionID":"part1","name":"Part 2"}"#),
        "delete_suite_section": Sample(#"{"assignmentPublicID":"$A","sectionID":"part1"}"#),
        "move_suite_item": Sample(#"{"assignmentPublicID":"$A","script":"test_a.sh","sectionID":"part1"}"#),
        "update_pattern_family": Sample(#"{"assignmentPublicID":"$A","familyID":"bmi","defaultPoints":2}"#),
        "create_pattern_family": Sample(
            #"{"assignmentPublicID":"$A","id":"bmi","name":"BMI","kind":"boundary_equality","function":"bmi","#
                + #""cases":[{"key":"low","args":[50,1.8],"expected":15.4}]}"#),
        "delete_suite_item": Sample(#"{"assignmentPublicID":"$A","script":"test_a.sh"}"#),
        "author_notebook_check": Sample(
            #"{"assignmentPublicID":"$A","id":"has_x","kind":"variable_exists","variable":"x"}"#),
        "update_notebook": Sample(#"{"assignmentPublicID":"$A","notebook":$NB}"#),
        "update_solution": Sample(#"{"assignmentPublicID":"$A","notebook":$NB}"#),
        "author_script": Sample(#"{"assignmentPublicID":"$A","filename":"test_new.sh","content":"exit 0\n"}"#),
        "delete_support_file": Sample(#"{"assignmentPublicID":"$A","filename":"cases.csv"}"#),
        "create_course_section": Sample(#"{"courseCode":"CS246","name":"Exams"}"#),
        "rename_course_section": Sample(#"{"courseSectionID":"$S","name":"Quizzes"}"#),
        "delete_course_section": Sample(#"{"courseSectionID":"$S"}"#, .answersAsUnknownID),
        "reorder_course_sections": Sample(#"{"courseCode":"CS246","orderedSectionIDs":["$S"]}"#),
        "set_assignment_course_section": Sample(#"{"assignmentPublicID":"$A","courseSectionID":"$S"}"#),
        "list_content_items": Sample(#"{"courseCode":"CS246"}"#),
        "create_content_item": Sample(
            #"{"courseCode":"CS246","title":"Reading","links":[{"label":"Notes","url":"https://example.com/notes"}]}"#),
        "update_content_item": Sample(#"{"contentItemID":"$C","title":"Renamed"}"#),
        "delete_content_item": Sample(#"{"contentItemID":"$C"}"#, .answersAsUnknownID),
        "reorder_content_items": Sample(#"{"courseCode":"CS246","orderedContentItemIDs":["$C"]}"#),
        "reorder_assignments": Sample(#"{"courseCode":"CS246","orderedAssignmentPublicIDs":["$A"]}"#),
        "reorder_section_items": Sample(
            #"{"courseCode":"CS246","orderedItems":[{"type":"assignment","id":"$A"},{"type":"content","id":"$C"}]}"#),
        "clone_assignment": Sample(#"{"sourceAssignmentPublicID":"$A","newTitle":"Copy"}"#),
        "create_assignment": Sample(#"{"courseCode":"CS246","title":"New lab","notebook":$NB,"language":"python"}"#),
        "list_reflections": Sample(#"{"assignmentPublicID":"$A"}"#),
        "get_reflections": Sample(#"{"assignmentPublicID":"$A","handle":"quiet-heron"}"#),
        "draft_feedback": Sample(
            #"{"assignmentPublicID":"$A","handle":"quiet-heron","feedback":"State the unit of each value."}"#),
    ]

    static let toolNames = MCPToolCatalog.live.all.map(\.name)

    private static let notebook =
        #"{"cells":[],"metadata":{"kernelspec":{"name":"python3","display_name":"Python 3"}},"nbformat":4,"nbformat_minor":5}"#

    private static let manifest = """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test_a.sh"}],\
        "timeLimitSeconds":10,"makefile":null,"language":"python"}
        """

    // MARK: - Contract

    @Test func everyToolHasASample() {
        let missing = Self.toolNames.filter { Self.samples[$0] == nil }
        #expect(missing.isEmpty, "Add a sample for: \(missing.joined(separator: ", "))")
        let stale = Set(Self.samples.keys).subtracting(Self.toolNames)
        #expect(stale.isEmpty, "Remove the samples for tools that are gone: \(stale.sorted())")
    }

    @Test(arguments: toolNames)
    func unenrolledSubjectIsDenied(_ name: String) async throws {
        let sample = try #require(Self.samples[name], "No sample for \(name)")
        let tool = try #require(MCPToolCatalog.live.tool(named: name))
        switch sample.denial {
        case .notAuthorized:
            let enrolled = try await outcome(tool, sample, enrolled: true)
            #expect(!enrolled.isNotAuthorized, "The enrolled run was refused: \(enrolled)")
            #expect(!enrolled.isOtherError, "The enrolled run failed: \(enrolled)")
            let unenrolled = try await outcome(tool, sample, enrolled: false)
            #expect(unenrolled.isNotAuthorized, "Expected notAuthorized, got \(unenrolled)")
        case .answersAsUnknownID:
            let enrolledReal = try await outcome(tool, sample, enrolled: true)
            let enrolledUnknown = try await outcome(tool, sample, enrolled: true, unknownIDs: true)
            #expect(enrolledReal != enrolledUnknown, "The enrolled run did not act on the real id")
            let unenrolledReal = try await outcome(tool, sample, enrolled: false)
            let unenrolledUnknown = try await outcome(tool, sample, enrolled: false, unknownIDs: true)
            #expect(unenrolledReal == unenrolledUnknown)
        case .omitsCourse:
            let enrolled = try await outcome(tool, sample, enrolled: true)
            #expect(enrolled.mentions(Self.courseCode), "The enrolled run did not list the course")
            let unenrolled = try await outcome(tool, sample, enrolled: false)
            #expect(!unenrolled.mentions(Self.courseCode), "The unenrolled run listed the course")
        case .notCourseScoped:
            let unenrolled = try await outcome(tool, sample, enrolled: false)
            #expect(!unenrolled.mentions(Self.courseCode))
        }
    }

    @Test(arguments: toolNames)
    func studentIsRefused(_ name: String) async throws {
        let sample = try #require(Self.samples[name], "No sample for \(name)")
        let tool = try #require(MCPToolCatalog.live.tool(named: name))
        let student = try await outcome(tool, sample, enrolled: false, asStudent: true)
        switch sample.denial {
        case .notAuthorized, .answersAsUnknownID:
            #expect(student.isNotAuthorized, "Expected notAuthorized, got \(student)")
        case .omitsCourse, .notCourseScoped:
            #expect(!student.mentions(Self.courseCode), "The student run showed the course")
        }
    }

    // MARK: - Running one tool

    /// The result of one call, with the seeded ids put back in place of the
    /// unknown ones so two calls compare equal when they answer alike.
    enum Outcome: Equatable, CustomStringConvertible {
        case output(String)
        case refused(MCPToolError)
        case other(String)

        var isNotAuthorized: Bool {
            if case .refused(.notAuthorized) = self { return true }
            return false
        }

        /// An error that is not an `MCPToolError`: the run broke, so the
        /// sample proves nothing.
        var isOtherError: Bool {
            if case .other = self { return true }
            return false
        }

        func mentions(_ text: String) -> Bool {
            if case .output(let json) = self { return json.contains(text) }
            return false
        }

        var description: String {
            switch self {
            case .output(let json): "output \(json.prefix(300))"
            case .refused(let error): "refused \(error)"
            case .other(let error): "error \(error)"
            }
        }
    }

    private func outcome(
        _ tool: AnyContentTool, _ sample: Sample, enrolled: Bool, unknownIDs: Bool = false,
        asStudent: Bool = false
    ) async throws -> Outcome {
        let app = try await makeTestApp()
        var result = Outcome.other("not run")
        try await withApp(app) { app in
            let world = try await seedWorld(on: app, enrolled: enrolled)
            var subject = mcpTestSubject
            if asStudent {
                subject = "pupil"
                let pupil = try await makeTestUser(on: app, username: subject, role: "student")
                try await makeTestEnrollment(on: app, userID: pupil.requireID(), courseID: world.courseID)
            }
            let section = unknownIDs ? Self.unknownID : world.sectionID.uuidString
            let item = unknownIDs ? Self.unknownID : world.contentItemID.uuidString
            let raw = sample.arguments
                .replacingOccurrences(of: "$NB", with: Self.notebook)
                .replacingOccurrences(of: "$A", with: world.assignmentPublicID)
                .replacingOccurrences(of: "$S", with: section)
                .replacingOccurrences(of: "$C", with: item)
            let arguments = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
            do {
                let output = try await tool.invoke(arguments, mcpContext(app, subject: subject))
                let data = try JSONEncoder.sortedKeys.encode(output)
                let json = try #require(String(bytes: data, encoding: .utf8))
                result = .output(
                    json
                        .replacingOccurrences(of: world.sectionID.uuidString, with: Self.unknownID)
                        .replacingOccurrences(of: world.contentItemID.uuidString, with: Self.unknownID))
            } catch let error as MCPToolError {
                result = .refused(error)
            } catch {
                result = .other(String(describing: error))
            }
        }
        return result
    }

    /// The course the samples target, with an assignment, a course section, a
    /// content item and a dataset in it. The acting account is an instructor
    /// in a second course in both runs, so it passes the MCP eligibility check
    /// and only the enrollment in the target course differs.
    private func seedWorld(on app: Application, enrolled: Bool) async throws -> World {
        let assignment = try await seedMCPAssignment(
            on: app, setupID: "setup_contract", manifest: Self.manifest, enroll: enrolled)
        let courseID = assignment.courseID
        let other = try await makeTestCourse(on: app, code: "CS999", name: "Other")
        let subject = try await mcpTestUser(on: app)
        try await makeTestEnrollment(on: app, userID: subject.requireID(), courseID: other.requireID())

        try await writeZipFixture(
            at: app.testSetupsDirectory + "setup_contract.zip",
            entries: [("test_a.sh", "exit 0\n"), ("cases.csv", "id,ward\n1,A\n2,B\n")])
        let section = APICourseSection(name: "Labs", sortOrder: 1, courseID: courseID)
        try await section.save(on: app.db)
        let item = APICourseContentItem(courseID: courseID, sortOrder: 1, title: "Syllabus")
        try await item.save(on: app.db)
        _ = try await CourseDatasetService.create(
            courseID: courseID, dataset: .init(name: "Ward cases", slug: "ward-cases"),
            upload: .init(filename: "cases.csv", bytes: Data("id,ward\n1,A\n2,B\n".utf8)),
            blobs: AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory), on: app.db)
        return World(
            courseID: courseID,
            assignmentPublicID: assignment.publicID,
            sectionID: try section.requireID(),
            contentItemID: try item.requireID())
    }
}

private extension JSONEncoder {
    static var sortedKeys: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
