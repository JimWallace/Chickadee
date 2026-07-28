// Tests/APITests/AssignmentVersionCaptureTests.swift
//
// End-to-end capture: an assignment content edit — made through the web
// instructor routes or through an MCP write tool — leaves a version history
// behind (docs/assignment-versioning.md).
//
// The unit-level contract (dedupe, numbering, baseline) is pinned in
// `AssignmentVersionStoreTests`. What these cover is the wiring: that the write
// seams actually fire, that the pre-edit baseline lands ahead of the edit, and
// that a failed or non-mutating request records nothing.
//
// `.serialized`: these spawn zip/unzip subprocesses, which hit the Foundation
// posix_spawn EFAULT race under within-suite parallelism.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AssignmentVersionCaptureTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-vcap")
    }

    // MARK: - Fixtures

    private func makeAssignment(
        scripts: [(String, String)] = [("publictest_a.py", "passed('a')\n")]
    ) async throws -> (publicID: String, setupID: String) {
        let courseID = UUID()
        let course = APICourse(
            id: courseID, code: "VCAP\(Int.random(in: 100...999))", name: "Capture",
            enrollmentMode: .auto)
        try await course.save(on: app.db)

        let setupID = "vcap_\(UUID().uuidString.prefix(8))"
        let zipPath = app.testSetupsDirectory + setupID + ".zip"
        try writeZip(at: zipPath, entries: [(".placeholder", "x")] + scripts)

        var entries: [ConfiguredSuiteEntry] = []
        for (index, (name, _)) in scripts.enumerated() {
            entries.append(
                ConfiguredSuiteEntry(
                    script: name, tier: "public", order: index + 1,
                    dependsOn: [], points: 1, displayName: nil))
        }
        let manifest = try makeWorkerManifestJSON(testSuites: entries, includeMakefile: false)
        let setup = APITestSetup(
            id: setupID, manifest: manifest, zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        let assignment = APIAssignment(
            testSetupID: setupID, title: "Capture lab", dueAt: nil, isOpen: true,
            deadlineOverrideActive: false, courseID: courseID)
        try await assignment.save(on: app.db)
        return (assignment.publicID, setupID)
    }

    private func writeZip(at zipPath: String, entries: [(String, String)]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vcap-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, content) in entries {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.data(using: .utf8)?.write(to: url)
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-q", "-r", zipPath, "."]
        zip.standardOutput = Pipe()
        zip.standardError = Pipe()
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)
    }

    private func versions(_ setupID: String) async throws -> [APIAssignmentVersion] {
        try await APIAssignmentVersion.query(on: app.db)
            .filter(\.$testSetupID == setupID)
            .sort(\.$versionNumber)
            .all()
    }

    // MARK: - Web capture

    /// The headline behaviour: editing the suite in the browser leaves a
    /// baseline of what it looked like before, plus the state it landed in.
    @Test func webSuiteEditRecordsBaselineThenTheEdit() async throws {
        try await withApp(app) { _ in
            let (publicID, setupID) = try await makeAssignment(scripts: [
                ("publictest_a.py", "passed('a')\n"),
                ("publictest_b.py", "passed('b')\n"),
            ])
            let cookie = try await loginUser(
                username: "vcap_inst", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("vcap_inst", on: app)
            let (csrf, sessionCookie) = try await csrfFields(
                for: "/instructor/\(publicID)/edit", cookie: cookie, on: app)

            let body = #"""
                {"items":[
                    {"kind":"script","script":{"script":"publictest_b.py","tier":"public","points":1,"displayName":null,"dependsOn":[]}},
                    {"kind":"script","script":{"script":"publictest_a.py","tier":"public","points":1,"displayName":null,"dependsOn":[]}}
                ]}
                """#
            try await app.asyncTest(
                .PUT, "/instructor/\(publicID)/suite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: body)
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "\(res.body.string)")
                })

            let history = try await versions(setupID)
            #expect(history.count == 2)
            #expect(history.first?.versionNumber == 1)
            #expect(history.first?.origin == AssignmentVersionOrigin.baseline)
            let edit = try #require(history.last)
            #expect(edit.versionNumber == 2)
            #expect(edit.origin.hasPrefix("web:"))
            #expect(edit.origin.contains("suite"))
            #expect(edit.actorUsername == "vcap_inst")
        }
    }

    /// The baseline must hold the content as it was BEFORE the edit — that is
    /// the whole reason it is seeded from the write seam rather than after the
    /// handler runs.
    @Test func theBaselineHoldsThePreEditContent() async throws {
        try await withApp(app) { _ in
            let (publicID, setupID) = try await makeAssignment(scripts: [
                ("publictest_a.py", "passed('a')\n")
            ])
            let before = try #require(try await APITestSetup.find(setupID, on: app.db)).manifest

            let cookie = try await loginUser(
                username: "vcap_pre", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("vcap_pre", on: app)
            let (csrf, sessionCookie) = try await csrfFields(
                for: "/instructor/\(publicID)/edit", cookie: cookie, on: app)

            // Retier the script: a real manifest change.
            let body = #"""
                {"items":[
                    {"kind":"script","script":{"script":"publictest_a.py","tier":"secret","points":5,"displayName":null,"dependsOn":[]}}
                ]}
                """#
            try await app.asyncTest(
                .PUT, "/instructor/\(publicID)/suite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: body)
                },
                afterResponse: { res in #expect(res.status == .ok, "\(res.body.string)") })

            let history = try await versions(setupID)
            #expect(history.count == 2)
            #expect(history.first?.manifest == before)
            let after = try #require(try await APITestSetup.find(setupID, on: app.db)).manifest
            #expect(history.last?.manifest == after)
            #expect(before != after)
        }
    }

    /// A read of the editor resolves no setup for write, so it must leave no
    /// history behind — otherwise every page load would inflate the timeline.
    @Test func readingTheSuiteRecordsNothing() async throws {
        try await withApp(app) { _ in
            let (publicID, setupID) = try await makeAssignment()
            let cookie = try await loginUser(
                username: "vcap_read", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("vcap_read", on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(publicID)/suite",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.status == .ok) })

            #expect(try await versions(setupID).isEmpty)
        }
    }

    /// A rejected write leaves the baseline (seeded at the seam, before the
    /// handler ran) but no edit version: the middleware gates on a 2xx
    /// precisely so a failed edit never gets a row describing a state that was
    /// never reached. Keeping the baseline is deliberate — it is the pre-edit
    /// content, and it is what makes the NEXT successful edit recoverable.
    @Test func aRejectedWriteRecordsNoEditVersion() async throws {
        try await withApp(app) { _ in
            let (publicID, setupID) = try await makeAssignment()
            let cookie = try await loginUser(
                username: "vcap_deny", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("vcap_deny", on: app)
            let (csrf, sessionCookie) = try await csrfFields(
                for: "/instructor/\(publicID)/edit", cookie: cookie, on: app)

            // Malformed: kind=script with no script payload.
            try await app.asyncTest(
                .PUT, "/instructor/\(publicID)/suite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: #"{"items":[{"kind":"script"}]}"#)
                },
                afterResponse: { res in #expect(res.status != .ok) })

            let history = try await versions(setupID)
            #expect(history.count == 1)
            #expect(history.first?.origin == AssignmentVersionOrigin.baseline)
        }
    }

    // MARK: - Scope

    // MARK: - MCP capture

    /// An MCP write tool is versioned by the seam it already uses to resolve
    /// its setup — the tool itself does nothing. `finishContentWrites` is what
    /// the dispatcher calls after a successful invoke.
    @Test func mcpWriteToolRecordsBaselineThenTheEdit() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "VMCP", name: "MCP Capture")
            let courseID = try course.requireID()
            let tester = try await makeTestUser(on: app, username: "vmcp", role: "instructor")
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)

            let setupID = "vmcp_setup"
            let manifest = """
                {"schemaVersion":1,"testSuites":[\
                {"tier":"public","script":"test_a.sh","points":1}\
                ],"timeLimitSeconds":10}
                """
            try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: manifest)
            try writeZip(
                at: app.testSetupsDirectory + setupID + ".zip",
                entries: [(".placeholder", "x"), ("test_a.sh", "exit 0\n")])
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: setupID, courseID: courseID, title: "MCP Lab")

            let context = ToolContext(
                request: Request(application: app, on: app.eventLoopGroup.any()),
                subject: "vmcp",
                grantedScopes: [.read, .write])

            _ = try await SetTimeLimitTool().execute(
                SetTimeLimitTool.Input(
                    assignmentPublicID: assignment.publicID, seconds: 45),
                context)
            await context.finishContentWrites(tool: "set_time_limit")

            let history = try await versions(setupID)
            #expect(history.count == 2)
            #expect(history.first?.origin == AssignmentVersionOrigin.baseline)
            let edit = try #require(history.last)
            #expect(edit.origin == "mcp:set_time_limit")
            #expect(edit.actorUsername == "vmcp")
            #expect(edit.manifest.contains("45"))
        }
    }

    /// The scope is drained once recorded, so a second call in the same request
    /// can't re-snapshot the first call's setups.
    @Test func drainingLeavesNothingForASecondCall() async throws {
        try await withApp(app) { _ in
            let (_, setupID) = try await makeAssignment()
            let setup = try #require(try await APITestSetup.find(setupID, on: app.db))
            let scope = MCPVersionCaptureScope()

            scope.register(setup)
            #expect(scope.drain().count == 1)
            #expect(scope.drain().isEmpty)
        }
    }
}

/// Guard for the web capture wiring itself.
///
/// A struct suite deliberately — it owns no Vapor app, so it can assert against
/// the production bootstrap without the class-suite `withApp` shutdown dance.
@Suite struct AssignmentVersionCaptureWiringTests {

    /// Capture rides the middleware chain the production bootstrap builds. The
    /// test app registers it explicitly (see `makeTestApp`), so nothing else
    /// would notice if the production registration were dropped — and dropped,
    /// it means a silent history hole for every browser edit.
    @Test func productionBootstrapRegistersTheCaptureMiddleware() throws {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/APITests/<thisFile>
        for _ in 0..<3 { url.deleteLastPathComponent() }  // -> repo root
        let source = try String(
            contentsOf: url.appendingPathComponent(
                "Sources/APIServer/Bootstrap/AppMiddleware.swift"),
            encoding: .utf8)
        #expect(source.contains("AssignmentVersionCaptureMiddleware()"))
    }

    /// The web write seam must seed the baseline before a handler mutates
    /// anything — after the fact the pre-edit content is already gone.
    @Test func theWebWriteSeamSeedsTheBaseline() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let source = try String(
            contentsOf: url.appendingPathComponent(
                "Sources/APIServer/Routes/Web/SuiteEditHelpers.swift"),
            encoding: .utf8)
        let seam = try #require(
            source.components(separatedBy: "func loadAssignmentAndSetupForWrite").last)
        #expect(
            seam.prefix(900).contains("beginAssignmentContentEdit("),
            "loadAssignmentAndSetupForWrite no longer seeds a version baseline — every instructor write route's history depends on it."
        )
    }
}
