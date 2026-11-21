// Tests/APITests/MCP/ReflectionFeedbackWallTests.swift
//
// The student-data wall around AI-assisted feedback
// (docs/ai-assisted-feedback.md, Sources/APIServer/MCP/CLAUDE.md), on paths
// that ReflectionFeedbackToolsTests and MCPAIFeedbackGateTests do not walk:
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
