// Tests that MCP `delete_support_file` and the web delete refuse the same
// files, because both now call `deleteFileFromSetup` (#2771). Before, the MCP
// path ran the steps by hand and skipped the `manifestDependents` check, so an
// agent could delete a support file that a suite entry still named in its
// `dependsOn`.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.timeLimit(.minutes(5))) struct DeleteSupportFileDependentsTests {
    /// One public test that depends on the support file `helpers.py`.
    private let dependentManifest = #"""
        {"schemaVersion":1,"testSuites":[{"tier":"public","script":"tests.py",\#
        "dependsOn":["helpers.py"]}],"timeLimitSeconds":10}
        """#

    private func fixture(on app: Application) async throws -> APIAssignment {
        let assignment = try await seedMCPAssignment(
            on: app, setupID: "setup_dep", manifest: dependentManifest)
        let zipPath = app.testSetupsDirectory + "setup_dep.zip"
        try await pfWriteEmptyZip(at: zipPath)
        try await updateScriptInZip(zipPath: zipPath, filename: "helpers.py", content: "X = 1\n")
        try await updateScriptInZip(zipPath: zipPath, filename: "tests.py", content: "print('ok')\n")
        return assignment
    }

    private func entries(_ app: Application) async -> [String] {
        await listZipEntries(zipPath: app.testSetupsDirectory + "setup_dep.zip")
    }

    @Test func mcpRefusesASupportFileThatATestDependsOn() async throws {
        try await withTestApp { app in
            let assignment = try await fixture(on: app)

            let error = await #expect(throws: MCPToolError.self) {
                try await DeleteSupportFileTool().execute(
                    DeleteSupportFileTool.Input(
                        assignmentPublicID: assignment.publicID, filename: "helpers.py"),
                    mcpContext(app))
            }
            guard case .invalidArguments(let detail) = error else {
                Issue.record("Expected invalidArguments, got \(String(describing: error)).")
                return
            }
            #expect(detail.contains("tests.py"), "the refusal names the dependent test")
            await #expect(entries(app).contains("helpers.py"), "the file must survive")

            let setup = try #require(try await APITestSetup.find("setup_dep", on: app.db))
            let props = try #require(setup.decodedManifest())
            #expect(props.testSuites.first?.dependsOn == ["helpers.py"], "the manifest is unchanged")
        }
    }

    @Test func webRefusesTheSameFile() async throws {
        try await withTestApp { app in
            _ = try await fixture(on: app)
            let setup = try #require(try await APITestSetup.find("setup_dep", on: app.db))

            await #expect(throws: WebAssignmentError.self) {
                try await deleteScriptFromSetup(setup: setup, filename: "helpers.py", on: app.db)
            }
            await #expect(entries(app).contains("helpers.py"), "the file must survive")
        }
    }

    @Test func serviceReportsTheDependents() async throws {
        try await withTestApp { app in
            _ = try await fixture(on: app)
            let setup = try #require(try await APITestSetup.find("setup_dep", on: app.db))

            await #expect(throws: SetupFileDeletionError.hasDependents(file: "helpers.py", dependents: ["tests.py"])) {
                try await deleteFileFromSetup(setup: setup, filename: "helpers.py", on: app.db)
            }
        }
    }
}
