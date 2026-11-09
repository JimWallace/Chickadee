// Tests/APITests/MCP/MCPAuthoringParityToolsTests.swift
//
// Three web authoring features that MCP gained in one sweep:
//
// - The pin of a hand-written test to a notebook cell (docs/notebook-guide.md,
//   "Pin to a cell"): `update_suite` writes it through `SuiteAnchorPinning`,
//   the rule the web route uses, and `get_suite` reports it. A pin-only call
//   does not close the assignment.
// - The reference render of a class composite (docs/class-composite.md):
//   `set_activity` with `prepareReference` queues one job per slot.
// - The GitHub submission setting (docs/github-submissions.md): `get_assignment`
//   reports it, read-only.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct MCPAuthoringParityToolsTests {

    // MARK: - Pins

    private let suiteManifest = """
        {"schemaVersion":1,"testSuites":[\
        {"tier":"public","script":"test_a.sh","points":1},\
        {"tier":"public","script":"test_b.sh","points":1}\
        ],"timeLimitSeconds":10}
        """

    private func suiteFixture(on app: Application) async throws -> APIAssignment {
        let assignment = try await seedMCPAssignment(on: app, setupID: "setup_pin", manifest: suiteManifest)
        try await writeZipFixture(
            at: app.testSetupsDirectory + "setup_pin.zip",
            entries: [(".placeholder", "x"), ("test_a.sh", "exit 0\n"), ("test_b.sh", "exit 0\n")])
        return assignment
    }

    private func pins(_ assignment: APIAssignment, on app: Application) async throws -> [String: String] {
        let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
        let entries = try #require(setup.decodedManifest()).testSuites
        return Dictionary(uniqueKeysWithValues: entries.compactMap { entry in entry.anchor.map { (entry.script, $0) } })
    }

    private func pin(
        _ assignment: APIAssignment, _ edits: [UpdateSuiteTool.ScriptEdit], on app: Application
    )
        async throws -> UpdateSuiteTool.Output
    {
        try await UpdateSuiteTool().execute(
            UpdateSuiteTool.Input(assignmentPublicID: assignment.publicID, edits: edits), mcpContext(app))
    }

    @Test func aPinOnlyEditSavesThePinAndLeavesTheAssignmentOpen() async throws {
        try await withTestApp { app in
            let assignment = try await suiteFixture(on: app)
            #expect(assignment.isOpen)
            let output = try await pin(
                assignment, [UpdateSuiteTool.ScriptEdit(script: "test_a.sh", anchor: "  mean_rate ")], on: app)
            #expect(output.updatedScripts == ["test_a.sh"])
            #expect(!output.assignmentClosed)
            #expect(try await pins(assignment, on: app) == ["test_a.sh": "mean_rate"])
            let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(reloaded.isOpen, "grading never reads a pin, so pinning must not close")
        }
    }

    @Test func getSuiteReportsThePinAndAnEmptyAnchorClearsIt() async throws {
        try await withTestApp { app in
            let assignment = try await suiteFixture(on: app)
            _ = try await pin(assignment, [UpdateSuiteTool.ScriptEdit(script: "test_b.sh", anchor: "summary")], on: app)

            let suite = try await GetSuiteTool().execute(
                GetSuiteTool.Input(assignmentPublicID: assignment.publicID), mcpContext(app))
            #expect(suite.items.first { $0.filename == "test_b.sh" }?.anchor == "summary")
            #expect(suite.items.first { $0.filename == "test_a.sh" }?.anchor == nil)

            _ = try await pin(assignment, [UpdateSuiteTool.ScriptEdit(script: "test_b.sh", anchor: "")], on: app)
            #expect(try await pins(assignment, on: app).isEmpty)
        }
    }

    @Test func aPinBesideAMetadataEditTakesTheFullPath() async throws {
        try await withTestApp { app in
            let assignment = try await suiteFixture(on: app)
            let output = try await pin(
                assignment,
                [
                    UpdateSuiteTool.ScriptEdit(script: "test_a.sh", points: 4),
                    UpdateSuiteTool.ScriptEdit(script: "test_b.sh", anchor: "summary"),
                ], on: app)
            #expect(output.assignmentClosed, "a points change still closes an open assignment")
            #expect(try await pins(assignment, on: app) == ["test_b.sh": "summary"])
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let points = try #require(setup.decodedManifest()).testSuites.first { $0.script == "test_a.sh" }?.points
            #expect(points == 4)
        }
    }

    @Test func aPinOnAnUnknownTestIsRefusedAndWritesNothing() async throws {
        try await withTestApp { app in
            let assignment = try await suiteFixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await pin(
                    assignment,
                    [
                        UpdateSuiteTool.ScriptEdit(script: "test_a.sh", anchor: "x"),
                        UpdateSuiteTool.ScriptEdit(script: "nope.sh", anchor: "y"),
                    ], on: app)
            }
            #expect(try await pins(assignment, on: app).isEmpty, "one refused pin refuses the whole edit")
        }
    }

    @Test func aRefusedPinBesideAMetadataEditSavesNeither() async throws {
        try await withTestApp { app in
            let assignment = try await suiteFixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await pin(
                    assignment,
                    [
                        UpdateSuiteTool.ScriptEdit(script: "test_a.sh", points: 4),
                        UpdateSuiteTool.ScriptEdit(script: "test_b.sh", anchor: "x"),
                        UpdateSuiteTool.ScriptEdit(script: "missing.sh", anchor: "y"),
                    ], on: app)
            }
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let entries = try #require(setup.decodedManifest()).testSuites
            #expect(entries.first { $0.script == "test_a.sh" }?.points == 1, "the points edit was not saved")
            #expect(entries.allSatisfy { $0.anchor == nil })
            let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(reloaded.isOpen)
        }
    }

    @Test func theServiceRefusesAGeneratedTest() async throws {
        try await withTestApp { app in
            let manifest = """
                {"schemaVersion":1,"testSuites":[\
                {"tier":"public","script":"publictest_bmi_01.py","points":1,"generatedBy":"bmi"}\
                ],"timeLimitSeconds":10}
                """
            let assignment = try await seedMCPAssignment(on: app, setupID: "setup_gen", manifest: manifest)
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            await #expect(throws: SuiteAnchorPinning.PinError.generated("publictest_bmi_01.py")) {
                try await SuiteAnchorPinning.apply(
                    [SuiteAnchorPinning.Pin(script: "publictest_bmi_01.py", anchor: "x")], setup: setup, on: app.db)
            }
        }
    }

    // MARK: - Reference renders

    private func compositeManifest() throws -> String {
        let spec = CompositeSpec(
            compositor: .tile, layout: .grid(columns: 2, rows: 2),
            contribution: CompositeContributionShape(width: 2, height: 1, frames: 1, format: .gray8),
            dealOrder: .rowMajor, emptySlots: .reference)
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "tile.py")], language: .python,
            activity: ClassActivity(kind: .classComposite, composite: spec))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    private func compositeInput(
        _ assignment: APIAssignment, kind: String = "classComposite"
    )
        -> SetActivityTool.Input
    {
        SetActivityTool.Input(
            assignmentPublicID: assignment.publicID, kind: kind, leaderboardVisibility: nil,
            prepareReference: true)
    }

    @Test func prepareReferenceOnAnotherKindIsRefusedBeforeTheSave() async throws {
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(
                on: app, setupID: "setup_ref_kind", manifest: try compositeManifest())
            await #expect(throws: MCPToolError.self) {
                _ = try await SetActivityTool().execute(compositeInput(assignment, kind: "bestMetric"), mcpContext(app))
            }
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            #expect(setup.decodedManifest()?.activity?.kind == .classComposite, "the refused call saved nothing")
        }
    }

    @Test func prepareReferenceWithNoSolutionIsRefusedBeforeTheSave() async throws {
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(
                on: app, setupID: "setup_ref_nosol", manifest: suiteManifest)
            let error = await #expect(throws: MCPToolError.self) {
                _ = try await SetActivityTool().execute(compositeInput(assignment), mcpContext(app))
            }
            #expect(String(describing: error).contains("update_solution"))
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            #expect(setup.decodedManifest()?.activity == nil, "the refused call saved nothing")
        }
    }

    @Test func prepareReferenceQueuesOneJobPerSlot() async throws {
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(
                on: app, setupID: "setup_ref_ok", manifest: try compositeManifest())
            let path = app.submissionsDirectory + "sol_ref_ok.ipynb"
            try #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#.write(
                to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
            try await APISubmission(
                id: "sol_ref_ok", testSetupID: assignment.testSetupID, zipPath: path, attemptNumber: 1,
                filename: "solution.ipynb", userID: nil, kind: APISubmission.Kind.validation
            ).save(on: app.db)
            assignment.validationSubmissionID = "sol_ref_ok"
            try await assignment.save(on: app.db)

            let output = try await SetActivityTool().execute(compositeInput(assignment), mcpContext(app))
            #expect(output.referenceJobsQueued == 4)
            let rows = try await APICompositeReference.query(on: app.db)
                .filter(\.$assignmentID == assignment.requireID()).count()
            #expect(rows == 4)
        }
    }

    @Test func aCallWithoutPrepareReferenceReportsNull() async throws {
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(
                on: app, setupID: "setup_ref_none", manifest: try compositeManifest())
            let output = try await SetActivityTool().execute(
                SetActivityTool.Input(
                    assignmentPublicID: assignment.publicID, kind: "classComposite", leaderboardVisibility: nil),
                mcpContext(app))
            #expect(output.referenceJobsQueued == nil)
            let json = try #require(String(bytes: try JSONEncoder().encode(output), encoding: .utf8))
            #expect(json.contains(#""referenceJobsQueued":null"#))
        }
    }

    // MARK: - GitHub submission, read-only

    @Test func getAssignmentReportsTheGitHubSettingOffByDefault() async throws {
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(on: app, setupID: "setup_gh_off", manifest: suiteManifest)
            let detail = try await GetAssignmentTool().execute(
                GetAssignmentTool.Input(assignmentPublicID: assignment.publicID), mcpContext(app))
            #expect(!detail.githubSubmission.enabled)
            #expect(!detail.githubSubmission.statusChecks)
            #expect(detail.githubSubmission.starterRepository == nil)
            let json = try #require(String(bytes: try JSONEncoder().encode(detail.githubSubmission), encoding: .utf8))
            #expect(json.contains(#""starterRepository":null"#))
        }
    }

    @Test func getAssignmentReportsTheStoredGitHubSetting() async throws {
        try await withTestApp { app in
            let manifest = """
                {"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10,"githubSubmission":true,\
                "githubStatusChecks":true,"githubStarterRepository":"course-org/starter"}
                """
            let assignment = try await seedMCPAssignment(on: app, setupID: "setup_gh_on", manifest: manifest)
            let detail = try await GetAssignmentTool().execute(
                GetAssignmentTool.Input(assignmentPublicID: assignment.publicID), mcpContext(app))
            #expect(detail.githubSubmission.enabled)
            #expect(detail.githubSubmission.statusChecks)
            #expect(detail.githubSubmission.starterRepository == "course-org/starter")
        }
    }

    @Test func noMCPToolWritesTheGitHubSetting() throws {
        let fields = ["githubSubmission", "githubStatusChecks", "githubStarterRepository"]
        for tool in MCPToolCatalog.live.all {
            let schema = try #require(String(bytes: try JSONEncoder().encode(tool.inputSchema), encoding: .utf8))
            #expect(!fields.contains { schema.contains($0) }, "\(tool.name) takes a GitHub submission field")
        }
    }
}
