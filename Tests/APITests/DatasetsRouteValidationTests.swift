// Tests/APITests/DatasetsRouteValidationTests.swift
//
// #1104 — PUT /instructor/:assignmentID/datasets must reject dataset specs
// whose `file` is anything but a bare filename naming a bundled support file.
// The value is joined onto directory paths at read time (DatasetResolver) and
// at delivery time on the server and the worker, so a separator or traversal
// component would read/write outside the setup directory (e.g.
// `../../.worker-secret` delivered back through the browser seed endpoint).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class DatasetsRouteValidationTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-datasets-val")
    }

    /// A published assignment whose setup zip bundles `cases.csv`, plus an
    /// authenticated instructor session for its course.
    private func fixture() async throws -> (assignmentID: String, cookie: String, csrf: String) {
        let course = APICourse(code: "DSV", name: "Datasets Validation", enrollmentMode: .auto)
        try await course.save(on: app.db)
        let courseID = try course.requireID()

        let setupID = "dsv_\(UUID().uuidString.prefix(8))"
        let zipPath = app.testSetupsDirectory + setupID + ".zip"
        try writeZip(at: zipPath, entries: [("cases.csv", "id\n1\n2\n3\n"), ("publictest_a.py", "passed('ok')\n")])
        let manifest = """
            {"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
            """
        let setup = APITestSetup(id: setupID, manifest: manifest, zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        let assignment = APIAssignment(
            testSetupID: setupID, title: "Datasets Lab",
            dueAt: nil, isOpen: true, deadlineOverrideActive: false, courseID: courseID)
        try await assignment.save(on: app.db)

        let cookie = try await loginUser(username: "dsv_inst", password: "pw", role: "user", on: app)
        try await promoteToInstructor("dsv_inst", on: app)
        let (csrf, sessionCookie) = try await csrfFields(
            for: "/instructor/\(assignment.publicID)/edit", cookie: cookie, on: app)
        return (assignment.publicID, sessionCookie, csrf)
    }

    private func writeZip(at zipPath: String, entries: [(String, String)]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsv-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, content) in entries {
            try content.data(using: .utf8)?.write(to: root.appendingPathComponent(name))
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

    private func putDatasets(
        _ fx: (assignmentID: String, cookie: String, csrf: String),
        body: String,
        expect expected: HTTPStatus,
        _ note: Comment
    ) async throws {
        try await app.asyncTest(
            .PUT, "/instructor/\(fx.assignmentID)/datasets",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: fx.cookie)
                req.headers.add(name: "x-csrf-token", value: fx.csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: body)
            },
            afterResponse: { res in
                #expect(res.status == expected, "\(note) — got \(res.status): \(res.body.string)")
            })
    }

    @Test func acceptsBundledBareFilename() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            try await putDatasets(
                fx, body: #"{"datasets":[{"file":"cases.csv","sampleSize":2}]}"#,
                expect: .ok, "a bundled bare filename is a valid dataset spec")
        }
    }

    @Test func rejectsTraversalFilename() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            try await putDatasets(
                fx, body: #"{"datasets":[{"file":"../../.worker-secret","sampleSize":2}]}"#,
                expect: .badRequest, "a traversal path must be rejected")
        }
    }

    @Test func rejectsAbsoluteAndNestedPaths() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            try await putDatasets(
                fx, body: #"{"datasets":[{"file":"/etc/hostname","sampleSize":2}]}"#,
                expect: .badRequest, "an absolute path must be rejected")
            try await putDatasets(
                fx, body: #"{"datasets":[{"file":"sub/dir.csv","sampleSize":2}]}"#,
                expect: .badRequest, "a nested path must be rejected")
        }
    }

    @Test func rejectsFileNotInSetupZip() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            try await putDatasets(
                fx, body: #"{"datasets":[{"file":"absent.csv","sampleSize":2}]}"#,
                expect: .badRequest, "a file the setup zip does not bundle must be rejected")
        }
    }
}
