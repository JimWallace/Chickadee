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
        on app: Application, id: String, manifest: String, withNotebook: Bool = true
    ) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(
            on: app, id: id, courseID: courseID, manifest: manifest, withNotebook: withNotebook)
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

    @Test func placeholderAuditReadsStudentNotebookBlob() async throws {
        // Regression: the audit must read the notebook the student actually
        // opens — the standalone `notebookPath` blob that `update_notebook` /
        // the editor write — which takes precedence over the test-setup zip's
        // starter entry. Before the fix the audit read the zip and missed
        // markers added via `update_notebook`. A *different* notebook in the zip
        // proves the audit prefers the blob.
        let manifest = #"""
            {"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10,"starterNotebook":"starter.ipynb","globalVariables":[{"name":"cap","value":5}]}
            """#
        let blobNotebook = #"""
            {"cells":[{"cell_type":"code","metadata":{},"source":["x = {{cap}}\n","y = {{missing}}"]}],"metadata":{},"nbformat":4,"nbformat_minor":5}
            """#
        let zipNotebook = #"""
            {"cells":[{"cell_type":"code","metadata":{},"source":["z = {{wrongzip}}"]}],"metadata":{},"nbformat":4,"nbformat_minor":5}
            """#
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await enrolledFixture(on: app, id: "setup_pv", manifest: manifest)
            try blobNotebook.write(
                toFile: app.testSetupsDirectory + "setup_pv.ipynb", atomically: true, encoding: .utf8)
            try writeZip(
                at: app.testSetupsDirectory + "setup_pv.zip",
                entries: [("starter.ipynb", zipNotebook)])

            let output = try await PreviewPersonalizationTool().execute(
                PreviewPersonalizationTool.Input(assignmentPublicID: assignment.publicID, seedHex: nil),
                context(app))
            #expect(output.placeholders.used == ["cap", "missing"])
            #expect(output.placeholders.unresolved == ["missing"])
        }
    }

    @Test func placeholderAuditFallsBackToZipStarter() async throws {
        // Legacy setups with no standalone notebook blob: the audit falls back
        // to the zip's starter entry, matching notebookData(for:) and the
        // student first-open path.
        let manifest = #"""
            {"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10,"starterNotebook":"starter.ipynb","globalVariables":[{"name":"cap","value":5}]}
            """#
        let notebook = #"""
            {"cells":[{"cell_type":"code","metadata":{},"source":["x = {{cap}}"]}],"metadata":{},"nbformat":4,"nbformat_minor":5}
            """#
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await enrolledFixture(
                on: app, id: "setup_pv", manifest: manifest, withNotebook: false)
            try writeZip(
                at: app.testSetupsDirectory + "setup_pv.zip",
                entries: [("starter.ipynb", notebook)])

            let output = try await PreviewPersonalizationTool().execute(
                PreviewPersonalizationTool.Input(assignmentPublicID: assignment.publicID, seedHex: nil),
                context(app))
            #expect(output.placeholders.used == ["cap"])
            #expect(output.placeholders.unresolved.isEmpty)
        }
    }

    @Test func auditIncludesPatternFamilyPerStudentRefs() async throws {
        // The audit covers grading, not just the notebook: a pattern-family
        // case that references per-student inputs (argVarRefs / expectedVarRef)
        // shows up in `used`, and resolves when the inputs are declared.
        let manifest = #"""
            {"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10,
            "globalExpressions":[{"name":"patients","expression":"[1, 2, 3]"},
            {"name":"adults_expected","expression":"2"}]}
            """#
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await enrolledFixture(
                on: app, id: "setup_pv", manifest: manifest, withNotebook: false)
            // Add a personalized family whose case references the per-student inputs.
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            try pfWriteEmptyZip(at: app.testSetupsDirectory + "setup_pv.zip")
            let famCase = PatternCase(
                key: "01", label: "Adults", args: [.null], expected: .null,
                argVarRefs: ["patients"], expectedVarRef: "adults_expected")
            let family = PatternFamily(
                id: "adults", name: "Adults", kind: .boundaryEquality,
                functionName: "countAdults", paramNames: ["patients"], cases: [famCase])
            try await applyPatternFamilies(
                to: setup, nextFamilies: [family],
                authoredItems: [.family(id: "adults", sectionID: nil)],
                on: app.db)

            let output = try await PreviewPersonalizationTool().execute(
                PreviewPersonalizationTool.Input(assignmentPublicID: assignment.publicID, seedHex: "ff"),
                context(app))
            #expect(output.placeholders.used.contains("patients"))
            #expect(output.placeholders.used.contains("adults_expected"))
            #expect(output.placeholders.unresolved.isEmpty)
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
