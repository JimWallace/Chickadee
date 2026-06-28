// Tests for AuthorScriptTool (create/replace a hand-written test or support
// file in the test-setup zip), backed by a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct AuthorScriptToolTests {
    /// The tool description must frame author_script as an escape hatch and
    /// point at the native check types, so an agent reaches for pattern families
    /// / notebook checks first for graded tests (regression guard for the
    /// "prefer native" steering).
    @Test func descriptionFramesItAsAnEscapeHatchPreferringNativeChecks() {
        let description = AuthorScriptTool.description
        #expect(description.contains("Escape hatch"))
        #expect(description.contains("create_pattern_family"))
        #expect(description.contains("author_notebook_check"))
    }

    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    private let manifest = """
        {"schemaVersion":1,"testSuites":[\
        {"tier":"public","script":"test_a.sh","points":1}\
        ],"timeLimitSeconds":10}
        """

    /// Course + enrolled instructor + setup (manifest above, with a real zip
    /// holding the script so applySuiteEdit can rebuild it) + assignment.
    private func fixture(on app: Application) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_as", courseID: courseID, manifest: manifest)
        try writeZip(
            at: app.testSetupsDirectory + "setup_as.zip",
            entries: [(".placeholder", "x"), ("test_a.sh", "exit 0\n")])
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_as", courseID: courseID, title: "Lab")
    }

    private func writeZip(at zipPath: String, entries: [(String, String)]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("as-zip-\(UUID().uuidString)")
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

    private func input(
        _ assignment: APIAssignment, filename: String, content: String? = nil,
        sourceUrl: String? = nil,
        tier: String? = nil, points: Int? = nil, displayName: String? = nil,
        dependsOn: [String]? = nil, sectionID: String? = nil,
        timeLimitSeconds: Int? = nil, graderOnly: Bool? = nil
    ) -> AuthorScriptTool.Input {
        AuthorScriptTool.Input(
            assignmentPublicID: assignment.publicID, filename: filename, content: content,
            sourceUrl: sourceUrl,
            tier: tier, points: points, displayName: displayName, dependsOn: dependsOn,
            sectionID: sectionID, timeLimitSeconds: timeLimitSeconds, graderOnly: graderOnly)
    }

    @Test func createsNewTestScriptWithMetadata() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let output = try await AuthorScriptTool().execute(
                input(
                    assignment, filename: "secrettest_marker.py",
                    content: "#!/usr/bin/env python3\nprint('ok')\n",
                    tier: "secret", points: 3, displayName: "Marker",
                    dependsOn: ["test_a.sh"]),
                context(app))
            #expect(output.created)
            #expect(output.isTest)
            #expect(output.tier == "secret")

            let reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let items = buildSuitePayload(fromManifest: reloaded.manifest, zipPath: reloaded.zipPath).items
            let row = try #require(items.first { $0.script?.script == "secrettest_marker.py" })
            #expect(row.script?.tier == .secret)
            #expect(row.script?.points == 3)
            #expect(row.script?.displayName == "Marker")
            #expect(row.script?.dependsOn == ["test_a.sh"])
            // The body landed in the zip verbatim.
            let body = try #require(readScriptFromZip(zipPath: reloaded.zipPath, filename: "secrettest_marker.py"))
            #expect(body.contains("print('ok')"))
        }
    }

    @Test func createsTestScriptWithPerTestTimeLimitOverride() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            _ = try await AuthorScriptTool().execute(
                input(
                    assignment, filename: "secrettest_slow.py",
                    content: "#!/usr/bin/env python3\nprint('ok')\n",
                    tier: "secret", timeLimitSeconds: 45),
                context(app))
            let reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let items = buildSuitePayload(fromManifest: reloaded.manifest, zipPath: reloaded.zipPath).items
            let row = try #require(items.first { $0.script?.script == "secrettest_slow.py" })
            #expect(row.script?.timeLimitSeconds == 45)
        }
    }

    @Test func rejectsOutOfRangePerTestTimeLimit() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await AuthorScriptTool().execute(
                    input(
                        assignment, filename: "secrettest_huge.py",
                        content: "#!/usr/bin/env python3\nprint('ok')\n",
                        tier: "secret", timeLimitSeconds: 9999),
                    context(app))
            }
        }
    }

    @Test func replacesExistingScriptBodyAndKeepsTierWhenOmitted() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            // Create as secret.
            _ = try await AuthorScriptTool().execute(
                input(assignment, filename: "t.py", content: "#!/usr/bin/env python3\nx=1\n", tier: "secret"),
                context(app))
            // Replace body without specifying tier — must stay secret.
            let output = try await AuthorScriptTool().execute(
                input(assignment, filename: "t.py", content: "#!/usr/bin/env python3\nx=2\n"),
                context(app))
            #expect(!output.created)
            #expect(output.tier == "secret")

            let reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let items = buildSuitePayload(fromManifest: reloaded.manifest, zipPath: reloaded.zipPath).items
            let row = try #require(items.first { $0.script?.script == "t.py" })
            #expect(row.script?.tier == .secret)
            let body = try #require(readScriptFromZip(zipPath: reloaded.zipPath, filename: "t.py"))
            #expect(body.contains("x=2"))
        }
    }

    @Test func writesSupportFileWithoutSuiteEntry() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let output = try await AuthorScriptTool().execute(
                input(assignment, filename: "helpers.py", content: "def gen():\n    return 1\n", tier: "support"),
                context(app))
            #expect(output.created)
            #expect(!output.isTest)
            #expect(output.tier == "support")

            let reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            // The file is in the zip but NOT a suite entry.
            #expect(listZipEntries(zipPath: reloaded.zipPath).contains("helpers.py"))
            let props = try #require(reloaded.decodedManifest())
            #expect(!props.testSuites.contains { $0.script == "helpers.py" })
        }
    }

    @Test func rejectsPathSeparatorsInFilename() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await AuthorScriptTool().execute(
                    input(assignment, filename: "../escape.py", content: "x=1\n"), context(app))
            }
        }
    }

    @Test func rejectsEmptyContent() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await AuthorScriptTool().execute(
                    input(assignment, filename: "t.py", content: ""), context(app))
            }
        }
    }

    @Test func rejectsInvalidTier() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await AuthorScriptTool().execute(
                    input(assignment, filename: "t.py", content: "x=1\n", tier: "bogus"), context(app))
            }
        }
    }

    /// Regression: an MCP content edit must re-run validation. The bearer
    /// context has no session `APIUser`, so `finalizeContentEdit` must thread
    /// the acting subject into the validation enqueue — otherwise the enqueue
    /// falls back to `req.auth.require(APIUser.self)`, throws 401, and
    /// `scheduleValidationAfterSuiteEdit` swallows it: the post-edit
    /// re-validation (and the `shared/solution.py` refresh it performs) is
    /// silently skipped. We prove the enqueue is reached by asserting a fresh
    /// validation submission is created.
    @Test func mcpEditEnqueuesRevalidationWithActingSubject() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let setupID = assignment.testSetupID
            let tester = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "tester").first())

            // An active runner so the availability pre-check passes (empty
            // capabilities match a default assignment, as the publish tests rely on).
            let runner = RunnerProfile()
            runner.runnerID = "runner-revalidate"
            runner.displayName = "Revalidate Runner"
            runner.platform = "linux"
            runner.architecture = "x86_64"
            runner.languageVersionsJSON = "[]"
            runner.capabilitiesJSON = "[]"
            runner.profileHash = nil
            runner.lastRegisteredAt = Date()
            runner.lastSeenAt = Date().addingTimeInterval(3600)
            runner.isActive = true
            try await runner.save(on: app.db)

            // A prior COMPLETED validation submission supplies the solution
            // notebook `loadExistingSolution` reads; being complete (not
            // pending) it does not debounce the new enqueue.
            let existing = try await makeTestSubmission(
                on: app, id: "sub_val_seed", setupID: setupID, userID: try tester.requireID(),
                kind: APISubmission.Kind.validation, status: "complete", filename: "solution.ipynb")
            assignment.validationSubmissionID = try existing.requireID()
            try await assignment.save(on: app.db)

            func validationCount() async throws -> Int {
                try await APISubmission.query(on: app.db)
                    .filter(\.$testSetupID == setupID)
                    .filter(\.$kind == APISubmission.Kind.validation)
                    .count()
            }
            #expect(try await validationCount() == 1)

            _ = try await AuthorScriptTool().execute(
                input(assignment, filename: "test_a.sh", content: "exit 0\n", tier: "public"),
                context(app))

            // The edit reached the (previously 401-blocked) revalidation path
            // and enqueued a fresh validation submission.
            #expect(try await validationCount() == 2)
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            _ = try await makeTestUser(on: app, username: "tester", role: "instructor")
            // tester NOT enrolled.
            try await makeTestSetup(on: app, id: "setup_as", courseID: courseID, manifest: manifest)
            try writeZip(
                at: app.testSetupsDirectory + "setup_as.zip",
                entries: [(".placeholder", "x"), ("test_a.sh", "exit 0\n")])
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_as", courseID: courseID, title: "Lab")
            await #expect(throws: MCPToolError.self) {
                _ = try await AuthorScriptTool().execute(
                    input(assignment, filename: "t.py", content: "x=1\n", tier: "secret"), context(app))
            }
        }
    }
}
