// Every question about an assignment's reference solution searches the same
// sources (#2488).
//
// Four functions used to search for the solution, over three different source
// lists. With only the unvalidated draft on disk, the `afterDue` guard said
// there was a solution and the reveal page served the draft, but MCP
// `get_solution` said there was none.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) struct SolutionResolverTests {

    private let draftNotebook = #"""
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
        {"cell_type":"code","metadata":{},"source":["answer = 42\n"],"outputs":[],"execution_count":null}
        ]}
        """#

    /// An assignment whose only solution is the draft written by "create
    /// solution".
    private func draftOnlyAssignment(on app: Application) async throws -> (APIAssignment, APITestSetup) {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        let setup = try await makeTestSetup(on: app, id: "setup_draft_sol", courseID: courseID)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "setup_draft_sol", courseID: courseID, title: "Lab")
        _ = try ensureDraftNotebookDirectory(
            testSetupsDirectory: app.testSetupsDirectory, setupID: "setup_draft_sol")
        try Data(draftNotebook.utf8).write(
            to: URL(
                fileURLWithPath: draftSolutionNotebookPath(
                    testSetupsDirectory: app.testSetupsDirectory, setupID: "setup_draft_sol")))
        return (assignment, setup)
    }

    @Test func aDraftOnlySolutionIsFoundByEveryReader() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (assignment, setup) = try await draftOnlyAssignment(on: app)

            #expect(
                try await assignmentHasSolution(
                    assignment: assignment, db: app.db, testSetupsDirectory: app.testSetupsDirectory))
            let served = try await solutionNotebookData(
                for: assignment, setup: setup, db: app.db, testSetupsDirectory: app.testSetupsDirectory)
            #expect(!served.isEmpty)

            let output = try await GetSolutionTool().execute(
                GetSolutionTool.Input(assignmentPublicID: assignment.publicID),
                ToolContext(
                    request: Request(application: app, on: app.eventLoopGroup.any()),
                    subject: "tester", grantedScopes: [.read]))
            #expect(output.cellCount == 1)
        }
    }

    /// A validation run uses only a validation submission, never the draft.
    @Test func aValidationRunDoesNotUseTheDraft() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (assignment, _) = try await draftOnlyAssignment(on: app)
            #expect(try await loadExistingSolution(assignment: assignment, on: app.db) == nil)
        }
    }

    /// The search order is fixed: the linked validation run wins over the
    /// draft.
    @Test func theLinkedValidationRunComesBeforeTheDraft() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (assignment, _) = try await draftOnlyAssignment(on: app)
            let path = app.submissionsDirectory + "sub_linked.ipynb"
            try Data(draftNotebook.utf8).write(to: URL(fileURLWithPath: path))
            try await APISubmission(
                id: "sub_linked", testSetupID: "setup_draft_sol", zipPath: path, attemptNumber: 1,
                filename: "validated.ipynb", userID: nil, kind: APISubmission.Kind.validation
            ).save(on: app.db)
            assignment.validationSubmissionID = "sub_linked"
            try await assignment.save(on: app.db)

            let found = try #require(
                try await resolveSolution(
                    at: SolutionLocation(assignment), sources: SolutionSource.any, db: app.db,
                    testSetupsDirectory: app.testSetupsDirectory))
            #expect(found.source == .linkedValidation)
            #expect(found.filename == "validated.ipynb")
        }
    }
}
