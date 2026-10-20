// Tests for SetGradingModeTool (set an assignment's worker/browser grading
// path), backed by a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct SetGradingModeToolTests {
    private let browserManifest =
        TestManifests.browserEmpty

    private func fixture(
        on app: Application, manifest: String, enroll: Bool = true
    ) async throws -> APIAssignment {
        try await seedMCPAssignment(
            on: app, setupID: "setup_gm", manifest: manifest, enroll: enroll)
    }

    @Test func setsGradingModeWithoutClosing() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, manifest: browserManifest)
            #expect(assignment.visibility == .open)

            let out = try await SetGradingModeTool().execute(
                .init(assignmentPublicID: assignment.publicID, gradingMode: "worker"), mcpContext(app))
            #expect(out.gradingMode == "worker")

            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            #expect(setup.decodedManifest()?.gradingMode.rawValue == "worker")
            // A grading-mode change is not a content edit, so the assignment stays open.
            let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(reloaded.visibility == .open)
        }
    }

    @Test func rejectsUnknownMode() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, manifest: browserManifest)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetGradingModeTool().execute(
                    .init(assignmentPublicID: assignment.publicID, gradingMode: "nonsense"), mcpContext(app))
            }
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, manifest: browserManifest, enroll: false)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetGradingModeTool().execute(
                    .init(assignmentPublicID: assignment.publicID, gradingMode: "worker"), mcpContext(app))
            }
        }
    }

    private let workerGraderOnlyManifest =
        #"{"schemaVersion":1,"gradingMode":"worker","graderOnlyFiles":["answers.py"],"testSuites":[],"timeLimitSeconds":10}"#

    /// Browser grading delivers the setup workspace into the student's kernel,
    /// so a manifest marking grader-only files refuses the switch — the
    /// reverse of author_script's refusal to mark files on a browser-graded
    /// assignment. Before this door closed, author-under-worker-then-switch
    /// reached the combination every authoring surface half-forbids.
    @Test func refusesBrowserWhileManifestMarksGraderOnlyFiles() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, manifest: workerGraderOnlyManifest)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetGradingModeTool().execute(
                    .init(assignmentPublicID: assignment.publicID, gradingMode: "browser"), mcpContext(app))
            }
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            #expect(setup.decodedManifest()?.gradingMode.rawValue == "worker")
        }
    }

    /// The refusal is scoped to marked files: a worker-graded assignment with
    /// none switches to browser exactly as before.
    @Test func allowsBrowserWhenNoGraderOnlyFilesMarked() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let workerManifest =
                #"{"schemaVersion":1,"gradingMode":"worker","graderOnlyFiles":[],"testSuites":[],"timeLimitSeconds":10}"#
            let assignment = try await fixture(on: app, manifest: workerManifest)
            let out = try await SetGradingModeTool().execute(
                .init(assignmentPublicID: assignment.publicID, gradingMode: "browser"), mcpContext(app))
            #expect(out.gradingMode == "browser")
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            #expect(setup.decodedManifest()?.gradingMode.rawValue == "browser")
        }
    }

    /// The mode-side door of the opponent refusal (docs/class-activities.md):
    /// an activity whose opponent the worker chooses at claim (the hill)
    /// keeps worker grading. The message is the one shared with the zip
    /// upload and set_activity.
    @Test func refusesBrowserWhileTheWorkerChoosesTheOpponent() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let opponentManifest =
                #"{"schemaVersion":1,"gradingMode":"worker","testSuites":[],"timeLimitSeconds":10,"activity":{"kind":"kingOfTheHill"}}"#
            let assignment = try await fixture(on: app, manifest: opponentManifest)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetGradingModeTool().execute(
                    .init(assignmentPublicID: assignment.publicID, gradingMode: "browser"), mcpContext(app))
            }
            let setup = try #require(try await APITestSetup.find("setup_gm", on: app.db))
            #expect(currentManifestGradingMode(setup.manifest) == "worker")
            do {
                _ = try await SetGradingModeTool().execute(
                    .init(assignmentPublicID: assignment.publicID, gradingMode: "browser"), mcpContext(app))
            } catch let error as MCPToolError {
                #expect(String(describing: error).contains(activityOpponentGradingConflictMessage))
            }
        }
    }

    /// A bot challenge may switch to browser grading: the browser runner
    /// stages the bot as the worker does.
    @Test func allowsBrowserForABotChallenge() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let botManifest =
                #"{"schemaVersion":1,"gradingMode":"worker","testSuites":[],"timeLimitSeconds":10,"activity":{"kind":"beatTheInstructor","opponentFile":"bot.py"}}"#
            let assignment = try await fixture(on: app, manifest: botManifest)
            _ = try await SetGradingModeTool().execute(
                .init(assignmentPublicID: assignment.publicID, gradingMode: "browser"), mcpContext(app))
            let setup = try #require(try await APITestSetup.find("setup_gm", on: app.db))
            #expect(currentManifestGradingMode(setup.manifest) == "browser")
        }
    }

    @Test func allowsBrowserForAnActivityWithNoOpponent() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let metricManifest =
                #"{"schemaVersion":1,"gradingMode":"worker","testSuites":[],"timeLimitSeconds":10,"activity":{"kind":"bestMetric"}}"#
            let assignment = try await fixture(on: app, manifest: metricManifest)
            let out = try await SetGradingModeTool().execute(
                .init(assignmentPublicID: assignment.publicID, gradingMode: "browser"), mcpContext(app))
            #expect(out.gradingMode == "browser")
        }
    }
}
