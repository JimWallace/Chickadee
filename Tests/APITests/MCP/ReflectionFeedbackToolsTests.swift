// Tests/APITests/MCP/ReflectionFeedbackToolsTests.swift
//
// Tests for the AI-assisted feedback tools (docs/ai-assisted-feedback.md):
// list_reflections, get_reflections and draft_feedback, backed by a real test
// database. They pin the two gates, the TA+ floor, that the agent sees a
// pseudonymous handle and never an identity, that a draft is never shown as
// released, and that released feedback cannot be overwritten by an agent.
//
// `ReflectionFeedbackWallTests` covers the student-data wall around the tools
// (Sources/APIServer/MCP/CLAUDE.md), on paths that the tool tests and
// MCPAIFeedbackGateTests do not walk:
//
// - `gatesOpen` is true only when both gates are exactly true; an unset gate
//   is closed.
// - No MCP path sets a gate: no tool's input schema names one,
//   update_assignment ignores one smuggled into its arguments, and
//   clone_assignment does not carry the source's assignment gate to the copy.
// - `ensureRows` falls back to one row at a time when the batch insert fails,
//   and the rows it keeps carry a pseudonymous handle only.
// - The written answers of a zipped submission are read from its notebook,
//   and only the tagged cells come back.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) struct ReflectionFeedbackToolsTests {
    private static let starter = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
        {"cell_type":"markdown","id":"q1","metadata":{},"source":["Why did you drop the outliers?"]},
        {"cell_type":"markdown","id":"a1","metadata":{"tags":["reflection"]},"source":["Your answer"]},
        {"cell_type":"code","id":"c1","metadata":{},"source":["x = 1"],"outputs":[],"execution_count":null},
        {"cell_type":"markdown","id":"q2","metadata":{},"source":["Is the median a better summary here?"]},
        {"cell_type":"markdown","id":"a2","metadata":{"tags":["reflection"]},"source":["Your answer"]}
        ]}
        """

    private static let aliceNotebook = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
        {"cell_type":"markdown","id":"q1","metadata":{},"source":["Why did you drop the outliers?"]},
        {"cell_type":"markdown","id":"a1","metadata":{"tags":["reflection"]},"source":["They were data-entry errors."]},
        {"cell_type":"code","id":"c1","metadata":{},"source":["secret_code = 42"],"outputs":[],"execution_count":1},
        {"cell_type":"markdown","id":"q2","metadata":{},"source":["Is the median a better summary here?"]},
        {"cell_type":"markdown","id":"a2","metadata":{"tags":["reflection"]},"source":["Yes, the data are skewed."]}
        ]}
        """

    private struct Fixture {
        let assignment: APIAssignment
        let course: APICourse
    }

    private func context(
        _ app: Application, subject: String = "tester",
        scopes: Set<ContentScope> = [.feedbackRead, .feedbackWrite]
    ) -> ToolContext {
        mcpContext(app, subject: subject, scopes: scopes, actingClientName: "Claude")
    }

    /// A course and assignment with both gates as given, an instructor
    /// "tester", and one student "alice" with a submission.
    private func fixture(
        on app: Application, courseGate: Bool = true, assignmentGate: Bool = true
    ) async throws -> Fixture {
        let course = try await makeTestCourse(on: app, code: "HLTH101", name: "Health Data")
        course.aiFeedbackEnabled = courseGate
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        let setup = try await makeTestSetup(on: app, id: "setup_fb", courseID: courseID)
        let starterPath = try #require(setup.notebookPath)
        try Self.starter.write(toFile: starterPath, atomically: true, encoding: .utf8)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "setup_fb", courseID: courseID, title: "Lab 3")
        assignment.aiFeedbackEnabled = assignmentGate
        try await assignment.save(on: app.db)

        let alice = try await makeTestStudent(on: app, username: "alice")
        try await makeTestEnrollment(on: app, userID: alice.requireID(), courseID: courseID)
        let submission = try await makeTestSubmission(
            on: app, id: "sub_alice_1", setupID: "setup_fb", userID: alice.requireID())
        try Self.aliceNotebook.write(toFile: submission.zipPath, atomically: true, encoding: .utf8)
        return Fixture(assignment: assignment, course: course)
    }

    private func list(_ app: Application, _ publicID: String) async throws -> ListReflectionsTool.Output {
        try await ListReflectionsTool().execute(.init(assignmentPublicID: publicID), context(app))
    }

    // MARK: - Gates

    @Test(arguments: [(false, true), (true, false), (false, false)])
    func everyToolRefusesUnlessBothGatesAreOn(courseGate: Bool, assignmentGate: Bool) async throws {
        try await withTestApp { app in
            let fx = try await fixture(on: app, courseGate: courseGate, assignmentGate: assignmentGate)
            let id = fx.assignment.publicID
            await #expect(throws: MCPToolError.self) { try await list(app, id) }
            await #expect(throws: MCPToolError.self) {
                try await GetReflectionsTool().execute(
                    .init(assignmentPublicID: id, handle: "R-222222"), context(app))
            }
            await #expect(throws: MCPToolError.self) {
                try await DraftFeedbackTool().execute(
                    .init(assignmentPublicID: id, handle: "R-222222", feedback: "Good."), context(app))
            }
            // A refused call makes no handle rows.
            #expect(try await APIReflectionFeedback.query(on: app.db).count() == 0)
        }
    }

    @Test func aStudentAccountIsRefused() async throws {
        try await withTestApp { app in
            let fx = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                try await ListReflectionsTool().execute(
                    .init(assignmentPublicID: fx.assignment.publicID), context(app, subject: "alice"))
            }
        }
    }

    // MARK: - Reading

    @Test func listReturnsHandlesAndNoIdentity() async throws {
        try await withTestApp { app in
            let fx = try await fixture(on: app)
            let out = try await list(app, fx.assignment.publicID)
            #expect(out.reflectionPromptCount == 2)
            let entry = try #require(out.students.first)
            #expect(out.students.count == 1)
            #expect(FeedbackHandle.isWellFormed(entry.handle))
            #expect(entry.feedbackState == "none")

            let json = try #require(String(bytes: try JSONEncoder().encode(out), encoding: .utf8))
            #expect(!json.contains("alice"))
            let aliceID = try #require(try await APIUser.query(on: app.db).filter(\.$username == "alice").first()?.id)
            #expect(!json.contains(aliceID.uuidString))

            // The handle is stable across calls.
            let again = try await list(app, fx.assignment.publicID)
            #expect(again.students.map(\.handle) == out.students.map(\.handle))
        }
    }

    @Test func getReturnsPromptsFromTheStarterAndOnlyTheTaggedAnswers() async throws {
        try await withTestApp { app in
            let fx = try await fixture(on: app)
            let handle = try #require(try await list(app, fx.assignment.publicID).students.first?.handle)
            let out = try await GetReflectionsTool().execute(
                .init(assignmentPublicID: fx.assignment.publicID, handle: handle), context(app))
            #expect(
                out.reflections == [
                    ReflectionPair(
                        index: 1, prompt: "Why did you drop the outliers?",
                        response: "They were data-entry errors."),
                    ReflectionPair(
                        index: 2, prompt: "Is the median a better summary here?",
                        response: "Yes, the data are skewed."),
                ])
            let json = try #require(String(bytes: try JSONEncoder().encode(out), encoding: .utf8))
            #expect(!json.contains("secret_code"))
            #expect(!json.contains("alice"))
        }
    }

    @Test func anUnknownHandleIsRefused() async throws {
        try await withTestApp { app in
            let fx = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                try await GetReflectionsTool().execute(
                    .init(assignmentPublicID: fx.assignment.publicID, handle: "R-222222"), context(app))
            }
            await #expect(throws: MCPToolError.self) {
                try await GetReflectionsTool().execute(
                    .init(assignmentPublicID: fx.assignment.publicID, handle: "alice"), context(app))
            }
        }
    }

    // MARK: - Drafting

    @Test func aDraftIsSavedButNotReleased() async throws {
        try await withTestApp { app in
            let fx = try await fixture(on: app)
            let handle = try #require(try await list(app, fx.assignment.publicID).students.first?.handle)
            let out = try await DraftFeedbackTool().execute(
                .init(assignmentPublicID: fx.assignment.publicID, handle: handle, feedback: "  Clear reasoning.  "),
                context(app))
            #expect(out.feedbackState == "draft")

            let row = try #require(try await APIReflectionFeedback.query(on: app.db).first())
            #expect(row.draftText == "Clear reasoning.")
            #expect(row.state == .draft)
            #expect(row.draftedByClient == "Claude")
            #expect(row.submissionID == "sub_alice_1")
            #expect(row.releasedAt == nil)
        }
    }

    @Test func releasedFeedbackCannotBeReplacedByAnAgent() async throws {
        try await withTestApp { app in
            let fx = try await fixture(on: app)
            let handle = try #require(try await list(app, fx.assignment.publicID).students.first?.handle)
            let row = try #require(try await APIReflectionFeedback.query(on: app.db).first())
            row.state = .released
            row.draftText = "Reviewed text."
            row.submissionID = "sub_alice_1"
            try await row.save(on: app.db)

            await #expect(throws: MCPToolError.self) {
                try await DraftFeedbackTool().execute(
                    .init(assignmentPublicID: fx.assignment.publicID, handle: handle, feedback: "New."),
                    context(app))
            }
            let reloaded = try #require(try await APIReflectionFeedback.find(row.id, on: app.db))
            #expect(reloaded.draftText == "Reviewed text.")
        }
    }

    @Test func aResubmissionMakesTheFeedbackStale() async throws {
        try await withTestApp { app in
            let fx = try await fixture(on: app)
            let handle = try #require(try await list(app, fx.assignment.publicID).students.first?.handle)
            _ = try await DraftFeedbackTool().execute(
                .init(assignmentPublicID: fx.assignment.publicID, handle: handle, feedback: "Good."),
                context(app))

            let alice = try #require(try await APIUser.query(on: app.db).filter(\.$username == "alice").first())
            let second = try await makeTestSubmission(
                on: app, id: "sub_alice_2", setupID: "setup_fb", userID: alice.requireID())
            second.submittedAt = Date().addingTimeInterval(60)
            try await second.save(on: app.db)

            let out = try await list(app, fx.assignment.publicID)
            #expect(out.students.first?.feedbackState == "stale")
        }
    }

    @Test(arguments: ["", "   ", String(repeating: "x", count: ReflectionFeedbackService.maxDraftLength + 1)])
    func emptyOrOverlongFeedbackIsRefused(feedback: String) async throws {
        try await withTestApp { app in
            let fx = try await fixture(on: app)
            let handle = try #require(try await list(app, fx.assignment.publicID).students.first?.handle)
            await #expect(throws: MCPToolError.self) {
                try await DraftFeedbackTool().execute(
                    .init(assignmentPublicID: fx.assignment.publicID, handle: handle, feedback: feedback),
                    context(app))
            }
        }
    }

    // MARK: - Scopes

    @Test func theToolsRequireTheFeedbackScopesOnly() {
        #expect(ListReflectionsTool.requiredScopes == [.feedbackRead])
        #expect(GetReflectionsTool.requiredScopes == [.feedbackRead])
        #expect(DraftFeedbackTool.requiredScopes == [.feedbackWrite])
        #expect(ContentScope.feedbackWrite.isWrite)
        #expect(!ContentScope.feedbackRead.isWrite)
        #expect(MCPMode.readOnly.scopeCeiling.contains(.feedbackRead))
        #expect(!MCPMode.readOnly.scopeCeiling.contains(.feedbackWrite))
    }
}

// MARK: - The student-data wall

@Suite(.serialized, .timeLimit(.minutes(5))) struct ReflectionFeedbackWallTests {
    private static let starter = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
        {"cell_type":"markdown","id":"q1","metadata":{},"source":["Why is the median robust?"]},
        {"cell_type":"markdown","id":"a1","metadata":{"tags":["reflection"]},"source":["Your answer"]},
        {"cell_type":"code","id":"c1","metadata":{},"source":["x = 1"],"outputs":[],"execution_count":null}
        ]}
        """

    private static func submittedNotebook(answer: String) -> String {
        """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
        {"cell_type":"markdown","id":"q1","metadata":{},"source":["Why is the median robust?"]},
        {"cell_type":"markdown","id":"a1","metadata":{"tags":["reflection"]},"source":["\(answer)"]},
        {"cell_type":"code","id":"c1","metadata":{},"source":["private_code = 7"],"outputs":[],"execution_count":1}
        ]}
        """
    }

    /// A course "HLTH230" and an assignment in it, with the two gates as
    /// given, and the MCP account enrolled as instructor.
    private func seedGatedAssignment(
        on app: Application, courseGate: Bool?, assignmentGate: Bool?
    ) async throws -> APIAssignment {
        let assignment = try await seedMCPAssignment(
            on: app, setupID: "setup_wall", courseCode: "HLTH230", title: "Lab 4")
        let course = try #require(try await APICourse.find(assignment.courseID, on: app.db))
        course.aiFeedbackEnabled = courseGate
        try await course.save(on: app.db)
        assignment.aiFeedbackEnabled = assignmentGate
        try await assignment.save(on: app.db)
        return assignment
    }

    // MARK: - The two gates

    @Test(
        arguments: [
            (Bool?.some(true), Bool?.some(true), true),
            (true, nil, false), (nil, true, false), (true, false, false), (false, true, false),
            (nil, nil, false),
        ])
    func gatesOpenOnlyWhenBothAreTrue(courseGate: Bool?, assignmentGate: Bool?, open: Bool) async throws {
        try await withTestApp { app in
            let assignment = try await seedGatedAssignment(
                on: app, courseGate: courseGate, assignmentGate: assignmentGate)
            #expect(try await ReflectionFeedbackService.gatesOpen(assignment, on: app.db) == open)
        }
    }

    // MARK: - No MCP path sets a gate

    @Test func noToolInputSchemaNamesAFeedbackGate() {
        for tool in MCPToolCatalog.live.all {
            let names = Self.propertyNames(in: tool.inputSchema)
            #expect(
                !names.contains { $0.lowercased().contains("aifeedback") },
                "\(tool.name) accepts an AI-feedback gate in its input")
        }
    }

    @Test func updateAssignmentIgnoresASmuggledGate() async throws {
        try await withTestApp { app in
            let assignment = try await seedGatedAssignment(on: app, courseGate: true, assignmentGate: nil)
            let tool = try #require(MCPToolCatalog.live.tool(named: UpdateAssignmentTool.name))
            let arguments: JSONValue = .object([
                "assignmentPublicID": .string(assignment.publicID),
                "title": .string("Lab 4 (revised)"),
                "aiFeedbackEnabled": .bool(true),
            ])
            // The tool may refuse the unknown key or ignore it. Either way the
            // gate stays closed.
            _ = try? await tool.invoke(arguments, mcpContext(app))

            let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(reloaded.aiFeedbackEnabled != true)
            #expect(try await ReflectionFeedbackService.gatesOpen(reloaded, on: app.db) == false)
        }
    }

    @Test func cloneAssignmentDoesNotCarryTheAssignmentGate() async throws {
        try await withTestApp { app in
            let source = try await seedGatedAssignment(on: app, courseGate: true, assignmentGate: true)
            #expect(try await ReflectionFeedbackService.gatesOpen(source, on: app.db))

            let out = try await CloneAssignmentTool().execute(
                .init(sourceAssignmentPublicID: source.publicID, newTitle: "Lab 4 copy", targetCourseCode: nil),
                mcpContext(app))

            let clone = try #require(try await assignmentByPublicID(out.publicID, on: app.db))
            #expect(clone.aiFeedbackEnabled != true)
            #expect(try await ReflectionFeedbackService.gatesOpen(clone, on: app.db) == false)
            await #expect(throws: MCPToolError.self) {
                _ = try await ListReflectionsTool().execute(
                    .init(assignmentPublicID: out.publicID),
                    mcpContext(app, scopes: [.feedbackRead, .feedbackWrite]))
            }
        }
    }

    // MARK: - Handle rows

    @Test func ensureRowsFallsBackOneRowAtATimeWhenTheBatchInsertFails() async throws {
        try await withTestApp { app in
            let assignment = try await seedGatedAssignment(on: app, courseGate: true, assignmentGate: true)
            let student = try await makeTestStudent(on: app, username: "wall_student")
            let studentID = try student.requireID()
            // No user has this id, so its row breaks the batch insert, and
            // then fails on its own row too, every time it is retried.
            let ghostID = UUID()

            await #expect(throws: (any Error).self) {
                _ = try await ReflectionFeedbackService.ensureRows(
                    for: assignment, userIDs: [studentID, ghostID], on: app.db)
            }

            // The fallback walks the missing ids in set order, so the
            // student's row exists only when it came before the ghost. Any
            // row that exists is the student's, under a handle only.
            let rows = try await APIReflectionFeedback.query(on: app.db)
                .filter(\.$assignmentID == assignment.requireID()).all()
            #expect(rows.allSatisfy { $0.userID == studentID })
            #expect(rows.count <= 1)
            let before = rows.first?.handle

            let again = try await ReflectionFeedbackService.ensureRows(
                for: assignment, userIDs: [studentID], on: app.db)
            let row = try #require(again[studentID])
            #expect(FeedbackHandle.isWellFormed(row.handle))
            #expect(!row.handle.contains("wall_student"))
            #expect(row.state == .none)
            if let before { #expect(row.handle == before) }
        }
    }

    // MARK: - Written answers from a zipped submission

    @Test(.requiresZipTools) func reflectionsAreReadFromTheNotebookInsideAZip() async throws {
        try await withTestApp { app in
            let assignment = try await seedGatedAssignment(on: app, courseGate: true, assignmentGate: true)
            let student = try await makeTestStudent(on: app, username: "zip_student")
            let submission = try await makeTestSubmission(
                on: app, id: "sub_zip_1", setupID: assignment.testSetupID, userID: student.requireID(),
                filename: "lab4.zip")
            let zipPath = app.submissionsDirectory + "sub_zip_1.zip"
            try await writeZipFixture(
                at: zipPath,
                entries: [
                    ("README.txt", "notes"),
                    ("work/scratch.ipynb", Self.submittedNotebook(answer: "From the scratch notebook.")),
                    ("work/assignment.ipynb", Self.submittedNotebook(answer: "Outliers pull the mean.")),
                ])
            submission.zipPath = zipPath
            try await submission.save(on: app.db)

            let pairs = await ReflectionFeedbackService.reflections(
                starter: Data(Self.starter.utf8), submission: submission)
            #expect(
                pairs == [
                    ReflectionPair(index: 1, prompt: "Why is the median robust?", response: "Outliers pull the mean.")
                ])
        }
    }

    @Test(.requiresZipTools) func aZipWithNoNotebookGivesPromptsWithoutAnswers() async throws {
        try await withTestApp { app in
            let assignment = try await seedGatedAssignment(on: app, courseGate: true, assignmentGate: true)
            let student = try await makeTestStudent(on: app, username: "zip_empty")
            let submission = try await makeTestSubmission(
                on: app, id: "sub_zip_2", setupID: assignment.testSetupID, userID: student.requireID(),
                filename: "lab4.zip")
            let zipPath = app.submissionsDirectory + "sub_zip_2.zip"
            try await writeZipFixture(at: zipPath, entries: [("main.py", "print(1)\n")])
            submission.zipPath = zipPath
            try await submission.save(on: app.db)

            #expect(await ReflectionFeedbackService.submittedNotebook(submission) == nil)
            let pairs = await ReflectionFeedbackService.reflections(
                starter: Data(Self.starter.utf8), submission: submission)
            #expect(pairs == [ReflectionPair(index: 1, prompt: "Why is the median robust?", response: nil)])
        }
    }

    // MARK: - Helpers

    /// Every key of every `properties` object in a JSON schema, at any depth.
    private static func propertyNames(in schema: JSONValue) -> [String] {
        switch schema {
        case .object(let fields):
            var names: [String] = []
            for (key, value) in fields {
                if key == "properties", case .object(let properties) = value {
                    names += properties.keys
                }
                names += propertyNames(in: value)
            }
            return names
        case .array(let values):
            return values.flatMap(propertyNames(in:))
        default:
            return []
        }
    }
}
