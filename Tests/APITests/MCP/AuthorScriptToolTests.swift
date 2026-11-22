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

    private let manifest = """
        {"schemaVersion":1,"testSuites":[\
        {"tier":"public","script":"test_a.sh","points":1}\
        ],"timeLimitSeconds":10}
        """

    /// Course + enrolled instructor + setup (manifest above, with a real zip
    /// holding the script so applySuiteEdit can rebuild it) + assignment.
    private func fixture(on app: Application) async throws -> APIAssignment {
        let assignment = try await seedMCPAssignment(
            on: app, setupID: "setup_as", manifest: manifest)
        try await writeZipFixture(
            at: app.testSetupsDirectory + "setup_as.zip",
            entries: [(".placeholder", "x"), ("test_a.sh", "exit 0\n")])
        return assignment
    }

    private func input(
        _ assignment: APIAssignment, filename: String, content: String? = nil,
        sourceUrl: String? = nil,
        tier: String? = nil, points: Int? = nil, displayName: String? = nil,
        dependsOn: [String]? = nil, sectionID: String? = nil,
        timeLimitSeconds: Int? = nil, failureDetail: String? = nil, graderOnly: Bool? = nil
    ) -> AuthorScriptTool.Input {
        AuthorScriptTool.Input(
            assignmentPublicID: assignment.publicID, filename: filename, content: content,
            sourceUrl: sourceUrl,
            tier: tier, points: points, displayName: displayName, dependsOn: dependsOn,
            sectionID: sectionID, timeLimitSeconds: timeLimitSeconds, failureDetail: failureDetail,
            graderOnly: graderOnly)
    }

    @Test func createsNewTestScriptWithMetadata() async throws {
        try await withTestApp { app in
            let assignment = try await fixture(on: app)
            let output = try await AuthorScriptTool().execute(
                input(
                    assignment, filename: "secrettest_marker.py",
                    content: "#!/usr/bin/env python3\nprint('ok')\n",
                    tier: "secret", points: 3, displayName: "Marker",
                    dependsOn: ["test_a.sh"]),
                mcpContext(app))
            #expect(output.created)
            #expect(output.isTest)
            #expect(output.tier == "secret")

            let reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let items = await buildSuitePayload(fromManifest: reloaded.manifest, zipPath: reloaded.zipPath).items
            let row = try #require(items.first { $0.script?.script == "secrettest_marker.py" })
            #expect(row.script?.tier == .secret)
            #expect(row.script?.points == 3)
            #expect(row.script?.displayName == "Marker")
            #expect(row.script?.dependsOn == ["test_a.sh"])
            // The body landed in the zip verbatim.
            let body = try #require(
                await readScriptFromZip(zipPath: reloaded.zipPath, filename: "secrettest_marker.py"))
            #expect(body.contains("print('ok')"))
        }
    }

    @Test func createsTestScriptWithPerTestTimeLimitOverride() async throws {
        try await withTestApp { app in
            let assignment = try await fixture(on: app)
            _ = try await AuthorScriptTool().execute(
                input(
                    assignment, filename: "secrettest_slow.py",
                    content: "#!/usr/bin/env python3\nprint('ok')\n",
                    tier: "secret", timeLimitSeconds: 45),
                mcpContext(app))
            let reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let items = await buildSuitePayload(fromManifest: reloaded.manifest, zipPath: reloaded.zipPath).items
            let row = try #require(items.first { $0.script?.script == "secrettest_slow.py" })
            #expect(row.script?.timeLimitSeconds == 45)
        }
    }

    @Test func rejectsOutOfRangePerTestTimeLimit() async throws {
        try await withTestApp { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await AuthorScriptTool().execute(
                    input(
                        assignment, filename: "secrettest_huge.py",
                        content: "#!/usr/bin/env python3\nprint('ok')\n",
                        tier: "secret", timeLimitSeconds: 9999),
                    mcpContext(app))
            }
        }
    }

    @Test func replacesExistingScriptBodyAndKeepsTierWhenOmitted() async throws {
        try await withTestApp { app in
            let assignment = try await fixture(on: app)
            // Create as secret.
            _ = try await AuthorScriptTool().execute(
                input(assignment, filename: "t.py", content: "#!/usr/bin/env python3\nx=1\n", tier: "secret"),
                mcpContext(app))
            // Replace body without specifying tier — must stay secret.
            let output = try await AuthorScriptTool().execute(
                input(assignment, filename: "t.py", content: "#!/usr/bin/env python3\nx=2\n"),
                mcpContext(app))
            #expect(!output.created)
            #expect(output.tier == "secret")

            let reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let items = await buildSuitePayload(fromManifest: reloaded.manifest, zipPath: reloaded.zipPath).items
            let row = try #require(items.first { $0.script?.script == "t.py" })
            #expect(row.script?.tier == .secret)
            let body = try #require(await readScriptFromZip(zipPath: reloaded.zipPath, filename: "t.py"))
            #expect(body.contains("x=2"))
        }
    }

    @Test func writesSupportFileWithoutSuiteEntry() async throws {
        try await withTestApp { app in
            let assignment = try await fixture(on: app)
            let output = try await AuthorScriptTool().execute(
                input(assignment, filename: "helpers.py", content: "def gen():\n    return 1\n", tier: "support"),
                mcpContext(app))
            #expect(output.created)
            #expect(!output.isTest)
            #expect(output.tier == "support")

            let reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            // The file is in the zip but NOT a suite entry.
            await #expect(listZipEntries(zipPath: reloaded.zipPath).contains("helpers.py"))
            let props = try #require(reloaded.decodedManifest())
            #expect(!props.testSuites.contains { $0.script == "helpers.py" })
        }
    }

    @Test func rejectsPathSeparatorsInFilename() async throws {
        try await withTestApp { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await AuthorScriptTool().execute(
                    input(assignment, filename: "../escape.py", content: "x=1\n"), mcpContext(app))
            }
        }
    }

    @Test func rejectsEmptyContent() async throws {
        try await withTestApp { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await AuthorScriptTool().execute(
                    input(assignment, filename: "t.py", content: ""), mcpContext(app))
            }
        }
    }

    @Test func rejectsInvalidTier() async throws {
        try await withTestApp { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await AuthorScriptTool().execute(
                    input(assignment, filename: "t.py", content: "x=1\n", tier: "bogus"), mcpContext(app))
            }
        }
    }

    @Test func reauthoringASupportFileWithoutATierKeepsItASupportFile() async throws {
        try await withTestApp { app in
            let assignment = try await fixture(on: app)
            _ = try await AuthorScriptTool().execute(
                input(assignment, filename: "helpers.py", content: "x = 1\n", tier: "support"),
                mcpContext(app))
            // No tier: a file already in the zip with no suite entry stays support.
            let output = try await AuthorScriptTool().execute(
                input(assignment, filename: "helpers.py", content: "x = 2\n"), mcpContext(app))
            #expect(!output.created)
            #expect(!output.isTest)
            #expect(output.tier == "support")

            let reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let props = try #require(reloaded.decodedManifest())
            #expect(!props.testSuites.contains { $0.script == "helpers.py" })
            let body = try #require(await readScriptFromZip(zipPath: reloaded.zipPath, filename: "helpers.py"))
            #expect(body.contains("x = 2"))
        }
    }

    @Test func refusesToDemoteAGradedTestToASupportFile() async throws {
        try await withTestApp { app in
            let assignment = try await fixture(on: app)
            let refusal = MCPToolError.invalidArguments(
                detail: "\"test_a.sh\" is currently a graded test; change its tier with update_suite "
                    + "or delete it before re-authoring it as a support file.")
            await #expect(throws: refusal) {
                _ = try await AuthorScriptTool().execute(
                    input(assignment, filename: "test_a.sh", content: "exit 0\n", tier: "support"),
                    mcpContext(app))
            }
            // The suite entry is still there.
            let reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let props = try #require(reloaded.decodedManifest())
            #expect(props.testSuites.contains { $0.script == "test_a.sh" })
        }
    }

    @Test func refusesToOverwriteAPatternFamilyGeneratedScript() async throws {
        let generated = """
            {"schemaVersion":1,"testSuites":[\
            {"tier":"public","script":"test_a.sh","points":1},\
            {"tier":"public","script":"publictest_bmi_01.py","generatedBy":"bmi"}\
            ],"timeLimitSeconds":10}
            """
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(
                on: app, setupID: "setup_as", manifest: generated)
            let refusal = MCPToolError.invalidArguments(
                detail: "\"publictest_bmi_01.py\" is generated from pattern family \"bmi\"; edit the family instead.")
            await #expect(throws: refusal) {
                _ = try await AuthorScriptTool().execute(
                    input(assignment, filename: "publictest_bmi_01.py", content: "print(1)\n"),
                    mcpContext(app))
            }
        }
    }

    // MARK: - graderOnly

    @Test func graderOnlyMarksAndUnmarksASupportFile() async throws {
        try await withTestApp { app in
            let assignment = try await fixture(on: app)
            _ = try await AuthorScriptTool().execute(
                input(
                    assignment, filename: "answers.py", content: "ANSWER = 42\n", tier: "support",
                    graderOnly: true),
                mcpContext(app))
            var reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            #expect(try #require(reloaded.decodedManifest()).graderOnlyFiles == ["answers.py"])

            // Marking it again does not add a second entry.
            _ = try await AuthorScriptTool().execute(
                input(
                    assignment, filename: "answers.py", content: "ANSWER = 43\n", tier: "support",
                    graderOnly: true),
                mcpContext(app))
            reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            #expect(try #require(reloaded.decodedManifest()).graderOnlyFiles == ["answers.py"])

            // graderOnly false removes the mark and keeps the file.
            _ = try await AuthorScriptTool().execute(
                input(
                    assignment, filename: "answers.py", content: "ANSWER = 44\n", tier: "support",
                    graderOnly: false),
                mcpContext(app))
            reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            #expect(try #require(reloaded.decodedManifest()).graderOnlyFiles.isEmpty)
            await #expect(listZipEntries(zipPath: reloaded.zipPath).contains("answers.py"))
        }
    }

    @Test func graderOnlyIsRefusedOnABrowserGradedAssignment() async throws {
        let browser = """
            {"schemaVersion":1,"gradingMode":"browser","testSuites":[\
            {"tier":"public","script":"test_a.sh","points":1}\
            ],"timeLimitSeconds":10}
            """
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(
                on: app, setupID: "setup_as", manifest: browser)
            try await writeZipFixture(
                at: app.testSetupsDirectory + "setup_as.zip",
                entries: [(".placeholder", "x"), ("test_a.sh", "exit 0\n")])
            let refusal = MCPToolError.invalidArguments(
                detail: "graderOnly requires worker grading, but this assignment is browser-graded. "
                    + "Switch it with set_grading_mode(\"worker\") first.")
            await #expect(throws: refusal) {
                _ = try await AuthorScriptTool().execute(
                    input(
                        assignment, filename: "answers.py", content: "ANSWER = 42\n", tier: "support",
                        graderOnly: true),
                    mcpContext(app))
            }
            // Nothing was written.
            let reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            await #expect(!listZipEntries(zipPath: reloaded.zipPath).contains("answers.py"))
            #expect(try #require(reloaded.decodedManifest()).graderOnlyFiles.isEmpty)
        }
    }

    // MARK: - failureDetail

    @Test func setsAndRevertsFailureDetail() async throws {
        try await withTestApp { app in
            let assignment = try await fixture(on: app)
            _ = try await AuthorScriptTool().execute(
                input(
                    assignment, filename: "publictest_masked.py",
                    content: "#!/usr/bin/env python3\nprint('ok')\n",
                    tier: "public", failureDetail: "actualOnly"),
                mcpContext(app))
            var reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            var items = await buildSuitePayload(fromManifest: reloaded.manifest, zipPath: reloaded.zipPath).items
            #expect(items.first { $0.script?.script == "publictest_masked.py" }?.script?.failureDetail == "actualOnly")

            // Replacing the body without mentioning the field leaves it alone.
            _ = try await AuthorScriptTool().execute(
                input(
                    assignment, filename: "publictest_masked.py",
                    content: "#!/usr/bin/env python3\nprint('still ok')\n"),
                mcpContext(app))
            reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            items = await buildSuitePayload(fromManifest: reloaded.manifest, zipPath: reloaded.zipPath).items
            #expect(items.first { $0.script?.script == "publictest_masked.py" }?.script?.failureDetail == "actualOnly")

            // "full" reverts to the default, stored as absence.
            _ = try await AuthorScriptTool().execute(
                input(
                    assignment, filename: "publictest_masked.py",
                    content: "#!/usr/bin/env python3\nprint('ok')\n", failureDetail: "full"),
                mcpContext(app))
            reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            items = await buildSuitePayload(fromManifest: reloaded.manifest, zipPath: reloaded.zipPath).items
            #expect(items.first { $0.script?.script == "publictest_masked.py" }?.script?.failureDetail == nil)
        }
    }

    @Test func rejectsAnUnknownFailureDetail() async throws {
        try await withTestApp { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await AuthorScriptTool().execute(
                    input(
                        assignment, filename: "publictest_x.py",
                        content: "#!/usr/bin/env python3\nprint('ok')\n", failureDetail: "some"),
                    mcpContext(app))
            }
        }
    }
}
