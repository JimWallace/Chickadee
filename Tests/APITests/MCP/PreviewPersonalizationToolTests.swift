// Tests for PreviewPersonalizationTool, backed by a real test database. The
// expression-eval paths run a real `python3` subprocess (like the
// PersonalizationEvaluator tests).

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct PreviewPersonalizationToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.read]
        )
    }

    private func enrolledFixture(
        on app: Application, id: String, manifest: String
    ) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: id, courseID: courseID, manifest: manifest)
        return try await makeTestAssignment(
            on: app, testSetupID: id, courseID: courseID, title: "Lab")
    }

    /// Writes a zip at `zipPath` containing the named entries (name -> contents).
    private func writeZip(at zipPath: String, entries: [(String, String)]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, content) in entries {
            try content.data(using: .utf8)?
                .write(to: root.appendingPathComponent(name))
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

    @Test func resolvesLiteralsAndExpressionsForExplicitSeed() async throws {
        let manifest = #"""
            {"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10,"globalVariables":[{"name":"cap","value":5}],"globalExpressions":[{"name":"offset","expression":"seed % 3"}]}
            """#
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await enrolledFixture(on: app, id: "setup_pv", manifest: manifest)
            // seed = 0xff = 255; 255 % 3 == 0.
            let output = try await PreviewPersonalizationTool().execute(
                PreviewPersonalizationTool.Input(
                    assignmentPublicID: assignment.publicID, seedHex: "ff"),
                context(app))
            #expect(output.seedHex == "ff")
            let byName = Dictionary(uniqueKeysWithValues: output.values.map { ($0.name, $0.value) })
            #expect(byName["cap"] == "5")
            #expect(byName["offset"] == "0")
            #expect(output.evaluatedExpressionNames == ["offset"])
            #expect(output.evaluationError == nil)
        }
    }

    @Test func literalOnlyNeedsNoSeed() async throws {
        let manifest = #"""
            {"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10,"globalVariables":[{"name":"cap","value":5}]}
            """#
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await enrolledFixture(on: app, id: "setup_pv", manifest: manifest)
            let output = try await PreviewPersonalizationTool().execute(
                PreviewPersonalizationTool.Input(assignmentPublicID: assignment.publicID, seedHex: nil),
                context(app))
            #expect(output.seedHex == nil)
            #expect(output.values.map(\.name) == ["cap"])
            #expect(output.evaluatedExpressionNames.isEmpty)
        }
    }

    @Test func invalidSeedThrows() async throws {
        let manifest = #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await enrolledFixture(on: app, id: "setup_pv", manifest: manifest)
            await #expect(throws: MCPToolError.self) {
                _ = try await PreviewPersonalizationTool().execute(
                    PreviewPersonalizationTool.Input(
                        assignmentPublicID: assignment.publicID, seedHex: "nothex"),
                    context(app))
            }
        }
    }

    @Test func placeholderAuditFlagsUnresolved() async throws {
        let manifest = #"""
            {"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10,"starterNotebook":"starter.ipynb","globalVariables":[{"name":"cap","value":5}]}
            """#
        let notebook = #"""
            {"cells":[{"cell_type":"code","metadata":{},"source":["x = {{cap}}\n","y = {{missing}}"]}],"metadata":{},"nbformat":4,"nbformat_minor":5}
            """#
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await enrolledFixture(on: app, id: "setup_pv", manifest: manifest)
            try writeZip(
                at: app.testSetupsDirectory + "setup_pv.zip",
                entries: [("starter.ipynb", notebook)])

            let output = try await PreviewPersonalizationTool().execute(
                PreviewPersonalizationTool.Input(assignmentPublicID: assignment.publicID, seedHex: nil),
                context(app))
            #expect(output.placeholders.used == ["cap", "missing"])
            #expect(output.placeholders.unresolved == ["missing"])
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let manifest = #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            _ = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestSetup(on: app, id: "setup_pv", courseID: courseID, manifest: manifest)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_pv", courseID: courseID, title: "Lab")
            await #expect(throws: MCPToolError.self) {
                _ = try await PreviewPersonalizationTool().execute(
                    PreviewPersonalizationTool.Input(assignmentPublicID: assignment.publicID, seedHex: nil),
                    context(app))
            }
        }
    }
}
