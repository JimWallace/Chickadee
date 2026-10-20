// Tests for AuthorNotebookCheckTool (create/replace a notebook check), backed by
// a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct AuthorNotebookCheckToolTests {
    private let emptyManifest =
        TestManifests.pythonDeclaredEmpty

    private func fixture(on app: Application) async throws -> APIAssignment {
        let assignment = try await seedMCPAssignment(
            on: app, setupID: "setup_nc", manifest: emptyManifest)
        try await pfWriteEmptyZip(at: app.testSetupsDirectory + "setup_nc.zip")
        return assignment
    }

    private func reloadCheck(
        _ assignment: APIAssignment, id: String, on db: any Database
    ) async throws -> NotebookCheck {
        let reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: db))
        let items = await buildSuitePayload(fromManifest: reloaded.manifest).items
        return try #require(items.compactMap(\.check).first { $0.id == id })
    }

    @Test func createsADataFrameShapeCheckAndCloses() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            #expect(assignment.visibility == .open)

            let out = try await AuthorNotebookCheckTool().execute(
                .init(
                    assignmentPublicID: assignment.publicID, id: "df_shape", kind: "data_frame_shape",
                    variable: "df", expectedRows: 250, expectedCols: 13),
                mcpContext(app))
            #expect(out.created)
            #expect(out.kind == "data_frame_shape")
            #expect(out.assignmentClosed)

            let check = try await reloadCheck(assignment, id: "df_shape", on: app.db)
            #expect(check.variable == "df")
            #expect(check.expectedRows == 250)
            #expect(check.expectedCols == 13)

            let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(reloaded.visibility == .closed)
        }
    }

    @Test func replacesAnExistingCheckByID() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            _ = try await AuthorNotebookCheckTool().execute(
                .init(
                    assignmentPublicID: assignment.publicID, id: "df_shape", kind: "data_frame_shape",
                    variable: "df", expectedRows: 1, expectedCols: 1),
                mcpContext(app))

            let out = try await AuthorNotebookCheckTool().execute(
                .init(
                    assignmentPublicID: assignment.publicID, id: "df_shape", kind: "data_frame_shape",
                    variable: "df", expectedRows: 9, expectedCols: 2),
                mcpContext(app))
            #expect(!out.created)

            let check = try await reloadCheck(assignment, id: "df_shape", on: app.db)
            #expect(check.expectedRows == 9)
            #expect(check.expectedCols == 2)

            // Replace, not append: still exactly one check row.
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            await #expect(buildSuitePayload(fromManifest: setup.manifest).items.compactMap(\.check).count == 1)
        }
    }

    @Test func figureCountCheck() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let out = try await AuthorNotebookCheckTool().execute(
                .init(assignmentPublicID: assignment.publicID, id: "figs", kind: "figure_count", minFigures: 2),
                mcpContext(app))
            #expect(out.created)
            let check = try await reloadCheck(assignment, id: "figs", on: app.db)
            #expect(check.minFigures == 2)
        }
    }

    @Test func setsCheckTimeLimitAndSurfacesInGetSuite() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            _ = try await AuthorNotebookCheckTool().execute(
                .init(
                    assignmentPublicID: assignment.publicID, id: "figs", kind: "figure_count",
                    timeLimitSeconds: 45, minFigures: 2),
                mcpContext(app))
            let check = try await reloadCheck(assignment, id: "figs", on: app.db)
            #expect(check.timeLimitSeconds == 45)

            // get_suite returns the value on the check spec.
            let readCtx = ToolContext(
                request: makeTestRequest(on: app),
                subject: "tester", grantedScopes: [.read])
            let suite = try await GetSuiteTool().execute(
                GetSuiteTool.Input(assignmentPublicID: assignment.publicID), readCtx)
            let row = try #require(suite.items.compactMap(\.check).first { $0.id == "figs" })
            #expect(row.timeLimitSeconds == 45)
        }
    }

    @Test func rejectsOutOfRangeCheckTimeLimit() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await AuthorNotebookCheckTool().execute(
                    .init(
                        assignmentPublicID: assignment.publicID, id: "figs", kind: "figure_count",
                        timeLimitSeconds: 601, minFigures: 1),
                    mcpContext(app))
            }
        }
    }

    @Test func rejectsUnknownKind() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await AuthorNotebookCheckTool().execute(
                    .init(assignmentPublicID: assignment.publicID, id: "x", kind: "not_a_kind"),
                    mcpContext(app))
            }
        }
    }

    @Test func rejectsMalformedSpec() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            // data_frame_shape requires variable + expectedRows + expectedCols; omit them.
            await #expect(throws: MCPToolError.self) {
                _ = try await AuthorNotebookCheckTool().execute(
                    .init(assignmentPublicID: assignment.publicID, id: "bad", kind: "data_frame_shape"),
                    mcpContext(app))
            }
        }
    }

    @Test func setsCheckFailureDetailAndSurfacesInGetSuite() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            _ = try await AuthorNotebookCheckTool().execute(
                .init(
                    assignmentPublicID: assignment.publicID, id: "figs", kind: "figure_count",
                    failureDetail: "verdictOnly", minFigures: 2),
                mcpContext(app))
            let check = try await reloadCheck(assignment, id: "figs", on: app.db)
            #expect(check.failureDetail == .verdictOnly)

            let readCtx = ToolContext(
                request: makeTestRequest(on: app),
                subject: "tester", grantedScopes: [.read])
            let suite = try await GetSuiteTool().execute(
                GetSuiteTool.Input(assignmentPublicID: assignment.publicID), readCtx)
            let row = try #require(suite.items.first { $0.check?.id == "figs" })
            #expect(row.failureDetail == "verdictOnly")
        }
    }
}
