// Tests/APITests/MCP/SetActivityOpponentTests.swift
//
// The opponent half of set_activity and the ActivityAuthoring core it shares
// with the edit page (docs/class-activities.md, slice 2): the file must be one
// of the setup's support files, a kind with no opponent takes none, an
// opponent kind is refused on a browser-graded assignment, an absent argument
// keeps the stored file while "" clears it, and get_assignment reports both
// the source and the file.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct SetActivityOpponentTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.read, .write]
        )
    }

    private let workerManifest =
        #"{"schemaVersion":1,"gradingMode":"worker","testSuites":[{"tier":"public","script":"match.sh"}],"timeLimitSeconds":10}"#
    private let browserManifest =
        #"{"schemaVersion":1,"gradingMode":"browser","testSuites":[],"timeLimitSeconds":10}"#

    /// Course + enrolled instructor + setup whose zip holds `support` beside
    /// the graded `match.sh`.
    private func fixture(
        on app: Application, manifest: String? = nil, support: [String] = ["bot.py"]
    ) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS135", name: "Designing Programs")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_opp", courseID: courseID, manifest: manifest ?? workerManifest)
        let zipPath = app.testSetupsDirectory + "setup_opp.zip"
        try await pfWriteEmptyZip(at: zipPath)
        try await updateScriptInZip(zipPath: zipPath, filename: "match.sh", content: "#!/bin/sh\nexit 0\n")
        for name in support {
            try await updateScriptInZip(zipPath: zipPath, filename: name, content: "print('rock')\n")
        }
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_opp", courseID: courseID, title: "RPS")
    }

    private func stored(on app: Application) async throws -> ClassActivity? {
        try #require(try await APITestSetup.find("setup_opp", on: app.db)).decodedManifest()?.activity
    }

    @Test func choosesASupportFileAndReportsIt() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let out = try await SetActivityTool().execute(
                .init(
                    assignmentPublicID: assignment.publicID, kind: "beatTheInstructor",
                    leaderboardVisibility: nil, opponentFile: "bot.py"),
                context(app))
            #expect(out.opponentSource == "supportFile")
            #expect(out.opponentFile == "bot.py")
            #expect(try await stored(on: app) == ClassActivity(kind: .beatTheInstructor, opponentFile: "bot.py"))

            let detail = try await GetAssignmentTool().execute(
                GetAssignmentTool.Input(assignmentPublicID: assignment.publicID), context(app))
            #expect(detail.activity?.opponentSource == "supportFile")
            #expect(detail.activity?.opponentFile == "bot.py")
        }
    }

    /// A graded script and a file the zip lacks are both refused, and the
    /// refusal lists what may be chosen.
    @Test func refusesAFileThatIsNotASupportFile() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            for bad in ["ghost.py", "match.sh", "../bot.py"] {
                await #expect(throws: MCPToolError.self, "\(bad)") {
                    _ = try await SetActivityTool().execute(
                        .init(
                            assignmentPublicID: assignment.publicID, kind: "beatTheInstructor",
                            leaderboardVisibility: nil, opponentFile: bad),
                        context(app))
                }
            }
            #expect(try await stored(on: app) == nil)
            #expect(ActivityAuthoring.opponentFileNotFoundMessage("ghost.py").contains("ghost.py"))
        }
    }

    @Test func refusesAFileOnAKindWithNoOpponent() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetActivityTool().execute(
                    .init(
                        assignmentPublicID: assignment.publicID, kind: "bestMetric",
                        leaderboardVisibility: nil, opponentFile: "bot.py"),
                    context(app))
            }
            #expect(try await stored(on: app) == nil)
        }
    }

    /// The kind's own door of the browser refusal; set_grading_mode holds the
    /// other. Choosing the bot is what is refused: the kind alone stages
    /// nothing and stays as free as it was in slice 1.
    @Test func refusesChoosingAnOpponentOnABrowserGradedAssignment() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, manifest: browserManifest)
            let kindOnly = try await SetActivityTool().execute(
                .init(
                    assignmentPublicID: assignment.publicID, kind: "beatTheInstructor", leaderboardVisibility: nil),
                context(app))
            #expect(kindOnly.opponentSource == "supportFile")
            #expect(kindOnly.opponentFile == nil)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetActivityTool().execute(
                    .init(
                        assignmentPublicID: assignment.publicID, kind: "beatTheInstructor",
                        leaderboardVisibility: nil, opponentFile: "bot.py"),
                    context(app))
            }
            #expect(try await stored(on: app) == ClassActivity(kind: .beatTheInstructor))
        }
    }

    /// The kind may be set before the bot exists; the file is chosen later.
    /// Absent keeps it across a visibility-only call, "" clears it, and a
    /// kind change starts from none.
    @Test func absentKeepsTheStoredFileAndEmptyClears() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let tool = SetActivityTool()
            let first = try await tool.execute(
                .init(assignmentPublicID: assignment.publicID, kind: "beatTheInstructor", leaderboardVisibility: nil),
                context(app))
            #expect(first.opponentFile == nil)

            _ = try await tool.execute(
                .init(
                    assignmentPublicID: assignment.publicID, kind: "beatTheInstructor",
                    leaderboardVisibility: nil, opponentFile: "bot.py"),
                context(app))
            let shown = try await tool.execute(
                .init(
                    assignmentPublicID: assignment.publicID, kind: "beatTheInstructor", leaderboardVisibility: "visible"
                ),
                context(app))
            #expect(shown.opponentFile == "bot.py")
            #expect(shown.leaderboardVisibility == "visible")

            let cleared = try await tool.execute(
                .init(
                    assignmentPublicID: assignment.publicID, kind: "beatTheInstructor",
                    leaderboardVisibility: nil, opponentFile: ""),
                context(app))
            #expect(cleared.opponentFile == nil)
            #expect(try await stored(on: app)?.leaderboardVisibility == .hidden)

            _ = try await tool.execute(
                .init(
                    assignmentPublicID: assignment.publicID, kind: "beatTheInstructor",
                    leaderboardVisibility: nil, opponentFile: "bot.py"),
                context(app))
            let switched = try await tool.execute(
                .init(assignmentPublicID: assignment.publicID, kind: "bestMetric", leaderboardVisibility: nil),
                context(app))
            #expect(switched.opponentFile == nil)
            #expect(switched.opponentSource == "none")
        }
    }

    /// The pure resolution rule, pinned apart from the database.
    @Test func resolvedOpponentFileRule() {
        let current = ClassActivity(kind: .beatTheInstructor, opponentFile: "bot.py")
        #expect(
            SetActivityTool.resolvedOpponentFile(input: nil, kind: .beatTheInstructor, current: current) == "bot.py")
        #expect(SetActivityTool.resolvedOpponentFile(input: nil, kind: .bestMetric, current: current) == nil)
        #expect(SetActivityTool.resolvedOpponentFile(input: "  ", kind: .beatTheInstructor, current: current) == nil)
        #expect(SetActivityTool.resolvedOpponentFile(input: " x.py ", kind: .beatTheInstructor, current: nil) == "x.py")
    }

    /// The server-info catalog reports the axis for every kind, derived.
    @Test func serverInfoReportsEveryKindsOpponentSource() {
        for capability in MCPActivityKindCapability.all {
            let kind = ActivityKind(rawValue: capability.name)
            #expect(capability.opponentSource == kind?.opponentSource.rawValue)
        }
    }
}
