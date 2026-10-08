// The one version-capture scope that the web middleware and the MCP dispatcher
// share (#2259, item 4).
//
// Each side used to have its own copy of the scope and of the record loop. The
// end-to-end wiring of each side is pinned in `AssignmentVersionCaptureTests`.
// These tests pin the shared steps themselves: `begin` seeds a baseline and
// registers the setup, and `recordRegistered` snapshots each registered setup
// with the caller's origin and then leaves the scope empty.
//
// `.serialized`: the fixture writes a zip, and zip subprocesses race under
// within-suite parallelism (see `AssignmentVersionCaptureTests`).

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AssignmentVersionCaptureScopeTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-vscope")
    }

    /// A setup with one test script, a published assignment and no version
    /// history. The store records only a setup that has an assignment.
    private func makeSetup() async throws -> APITestSetup {
        let courseID = UUID()
        try await APICourse(
            id: courseID, code: "VSCOPE\(Int.random(in: 100...999))", name: "Scope",
            enrollmentMode: .auto
        ).save(on: app.db)
        let setupID = "vscope_\(UUID().uuidString.prefix(8))"
        let zipPath = app.testSetupsDirectory + setupID + ".zip"
        try await writeZipFixture(at: zipPath, entries: [(".placeholder", "x"), ("publictest_a.py", "a\n")])
        let manifest = try makeWorkerManifestJSON(
            testSuites: [
                ConfiguredSuiteEntry(
                    script: "publictest_a.py", tier: "public", order: 1, dependsOn: [], points: 1,
                    displayName: nil)
            ],
            includeMakefile: false, language: nil)
        let setup = APITestSetup(id: setupID, manifest: manifest, zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        try await APIAssignment(
            testSetupID: setupID, title: "Scope lab", dueAt: nil, isOpen: true,
            deadlineOverrideActive: false, courseID: courseID
        ).save(on: app.db)
        return setup
    }

    private func versions(_ setupID: String) async throws -> [APIAssignmentVersion] {
        try await APIAssignmentVersion.query(on: app.db)
            .filter(\.$testSetupID == setupID)
            .sort(\.$versionNumber)
            .all()
    }

    @Test func beginSeedsTheBaselineAndRegistersTheSetup() async throws {
        try await withApp(app) { _ in
            let setup = try await makeSetup()
            let scope = AssignmentVersionCaptureScope()

            await scope.begin(
                setup: setup, testSetupsDirectory: app.testSetupsDirectory, logger: app.logger, on: app.db)

            #expect(!scope.isEmpty)
            let history = try await versions(try setup.requireID())
            #expect(history.map(\.origin) == [AssignmentVersionOrigin.baseline])
        }
    }

    @Test func recordRegisteredSnapshotsWithTheCallersOriginAndDrains() async throws {
        try await withApp(app) { _ in
            let setup = try await makeSetup()
            let setupID = try setup.requireID()
            let scope = AssignmentVersionCaptureScope()
            await scope.begin(
                setup: setup, testSetupsDirectory: app.testSetupsDirectory, logger: app.logger, on: app.db)

            // An edit after the baseline: the snapshot must read what
            // persisted, so change the stored row, not the registered object.
            let stored = try #require(try await APITestSetup.find(setupID, on: app.db))
            try await mutateManifest(setup: stored, on: app.db) { $0.timeLimitSeconds = 45 }

            await scope.recordRegistered(
                origin: AssignmentVersionOrigin.mcp(tool: "update_suite"), actor: nil,
                testSetupsDirectory: app.testSetupsDirectory, logger: app.logger, on: app.db)

            #expect(scope.isEmpty)
            let history = try await versions(setupID)
            #expect(history.map(\.origin) == [AssignmentVersionOrigin.baseline, "mcp:update_suite"])
            #expect(history.last?.manifest.contains("45") == true)
        }
    }
}
