// Tests for UpdateSuiteTool (per-script suite metadata edits), backed by a real
// test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct UpdateSuiteToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    private let manifest = """
        {"schemaVersion":1,"testSuites":[\
        {"tier":"public","script":"test_a.sh","points":1},\
        {"tier":"public","script":"test_b.sh","points":1}\
        ],"timeLimitSeconds":10}
        """

    /// Course + enrolled instructor + setup (manifest above, with a real zip
    /// holding the two scripts so applySuiteEdit can rebuild it) + assignment.
    private func fixture(on app: Application) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_us", courseID: courseID, manifest: manifest)
        // Replace the empty fixture zip with one that actually contains the
        // scripts named in the manifest, so the suite-edit zip rebuild succeeds.
        try writeZip(
            at: app.testSetupsDirectory + "setup_us.zip",
            entries: [(".placeholder", "x"), ("test_a.sh", "exit 0\n"), ("test_b.sh", "exit 0\n")])
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_us", courseID: courseID, title: "Lab")
    }

    private func writeZip(at zipPath: String, entries: [(String, String)]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("us-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, content) in entries {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.data(using: .utf8)?.write(to: url)
        }
        try? FileManager.default.removeItem(atPath: zipPath)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-q", "-r", zipPath, "."]
        zip.standardOutput = Pipe()
        zip.standardError = Pipe()
        try zip.run()
        zip.waitUntilExit()
    }

    @Test func updatesScriptTierAndPoints() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let output = try await UpdateSuiteTool().execute(
                UpdateSuiteTool.Input(
                    assignmentPublicID: assignment.publicID,
                    edits: [
                        UpdateSuiteTool.ScriptEdit(
                            script: "test_a.sh", tier: "secret", points: 5, displayName: "First",
                            dependsOn: nil, sectionID: nil)
                    ]),
                context(app))
            #expect(output.updatedScripts == ["test_a.sh"])

            // Reload the persisted manifest and confirm the edit stuck.
            let reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let items = buildSuitePayload(fromManifest: reloaded.manifest).items
            let a = try #require(items.first { $0.script?.script == "test_a.sh" })
            #expect(a.script?.tier == .secret)
            #expect(a.script?.points == 5)
            #expect(a.script?.displayName == "First")
            // The untouched script is unchanged.
            let b = try #require(items.first { $0.script?.script == "test_b.sh" })
            #expect(b.script?.tier == .pub)
            #expect(b.script?.points == 1)
        }
    }

    @Test func setsDependsOn() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            _ = try await UpdateSuiteTool().execute(
                UpdateSuiteTool.Input(
                    assignmentPublicID: assignment.publicID,
                    edits: [
                        UpdateSuiteTool.ScriptEdit(
                            script: "test_b.sh", tier: nil, points: nil, displayName: nil,
                            dependsOn: ["test_a.sh"], sectionID: nil)
                    ]),
                context(app))
            let reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let items = buildSuitePayload(fromManifest: reloaded.manifest).items
            let b = try #require(items.first { $0.script?.script == "test_b.sh" })
            #expect(b.script?.dependsOn == ["test_a.sh"])
        }
    }

    @Test func unknownScriptThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateSuiteTool().execute(
                    UpdateSuiteTool.Input(
                        assignmentPublicID: assignment.publicID,
                        edits: [
                            UpdateSuiteTool.ScriptEdit(
                                script: "nope.sh", tier: "secret", points: nil, displayName: nil,
                                dependsOn: nil, sectionID: nil)
                        ]),
                    context(app))
            }
        }
    }

    @Test func invalidTierThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateSuiteTool().execute(
                    UpdateSuiteTool.Input(
                        assignmentPublicID: assignment.publicID,
                        edits: [
                            UpdateSuiteTool.ScriptEdit(
                                script: "test_a.sh", tier: "bogus", points: nil, displayName: nil,
                                dependsOn: nil, sectionID: nil)
                        ]),
                    context(app))
            }
        }
    }

    @Test func emptyEditsThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateSuiteTool().execute(
                    UpdateSuiteTool.Input(assignmentPublicID: assignment.publicID, edits: []),
                    context(app))
            }
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            _ = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestSetup(on: app, id: "setup_us", courseID: courseID, manifest: manifest)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_us", courseID: courseID, title: "Lab")
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateSuiteTool().execute(
                    UpdateSuiteTool.Input(
                        assignmentPublicID: assignment.publicID,
                        edits: [
                            UpdateSuiteTool.ScriptEdit(
                                script: "test_a.sh", tier: "secret", points: nil, displayName: nil,
                                dependsOn: nil, sectionID: nil)
                        ]),
                    context(app))
            }
        }
    }
}
