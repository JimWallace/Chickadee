// Tests/APITests/PatternFamilyRouteTests.swift
//
// HTTP tests for GET and PUT /instructor/:assignmentID/families.  Exercises
// the full round-trip: PUT a family list, GET reads it back, raw-script
// endpoints reject edits of generated files.

import XCTest
import XCTVapor
@testable import chickadee_server
import Fluent
import Foundation
import Core

final class PatternFamilyRouteTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    override func setUp() async throws {
        app = try await Application.make(.testing)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-pf-routes-\(UUID().uuidString)/")
            .path

        for dir in ["results/", "testsetups/", "submissions/"].map({ tmpDir + $0 }) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        app.resultsDirectory     = tmpDir + "results/"
        app.testSetupsDirectory  = tmpDir + "testsetups/"
        app.submissionsDirectory = tmpDir + "submissions/"

        app.sessions.use(.memory)
        app.middleware.use(app.sessions.middleware)

        try await configureTestDatabase(app)
        configureLeaf(app)
        try routes(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    // MARK: - Test fixture

    /// Sets up a minimal assignment with an empty test setup zip.  Returns
    /// the assignment's public id for use in URL paths.
    private func makeAssignment() async throws -> String {
        let courseID = UUID()
        let course = APICourse(id: courseID, code: "PF101", name: "Pattern Family Routes Test", enrollmentMode: .auto)
        try await course.save(on: app.db)

        let setupID = "pf_rt_\(UUID().uuidString.prefix(8))"
        let zipPath = app.testSetupsDirectory + setupID + ".zip"
        try writeZip(at: zipPath, entries: [(".placeholder", "x")])

        let manifest = try makeWorkerManifestJSON(testSuites: [], includeMakefile: false)
        let setup = APITestSetup(id: setupID, manifest: manifest, zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)

        let assignment = APIAssignment(
            testSetupID: setupID, title: "PF Route Test",
            dueAt: nil, isOpen: true, deadlineOverrideActive: false,
            courseID: courseID
        )
        try await assignment.save(on: app.db)
        return assignment.publicID
    }

    private func writeZip(at zipPath: String, entries: [(String, String)]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf-rt-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, content) in entries {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.data(using: .utf8)?.write(to: url)
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-q", "-r", zipPath, "."]
        zip.standardOutput = Pipe()
        zip.standardError  = Pipe()
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
    }

    private func sampleFamilyJSON() -> String {
        #"""
        [{
            "id": "bmi_category",
            "name": "BMI Boundaries",
            "kind": "boundary_equality",
            "functionName": "bmi_category",
            "paramNames": ["bmi"],
            "defaults": {"tier": "public", "points": 1, "hint": "shared hint"},
            "cases": [
                {"key": "01", "label": "BMI < 18.5 is underweight",
                 "args": [18.49], "expected": "underweight", "enabled": true},
                {"key": "02", "label": "BMI = 18.5 is normal",
                 "args": [18.5],  "expected": "normal",      "enabled": true}
            ]
        }]
        """#
    }

    // MARK: - Tests

    func testGetFamilies_emptyByDefault() async throws {
        let id = try await makeAssignment()
        let cookie = try await loginUser(username: "inst", password: "pw", role: "instructor", on: app)
        try await app.asyncTest(.GET, "/instructor/\(id)/families", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let body = res.body.string
            XCTAssertEqual(body, "[]")
        })
    }

    func testPutFamilies_acceptsValidSpecAndRendersScripts() async throws {
        let id = try await makeAssignment()
        let cookie = try await loginUser(username: "inst", password: "pw", role: "instructor", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        try await app.asyncTest(.PUT, "/instructor/\(id)/families", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.add(name: "x-csrf-token", value: csrf)
            req.headers.contentType = .json
            req.body = ByteBuffer(string: sampleFamilyJSON())
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            // Response echoes the applied list.
            XCTAssertTrue(res.body.string.contains("bmi_category"))
        })

        // Confirm via GET that state is persistent.
        try await app.asyncTest(.GET, "/instructor/\(id)/families", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("\"id\":\"bmi_category\""))
            XCTAssertTrue(res.body.string.contains("\"key\":\"01\""))
        })

        // The zip now contains the generated .py files.
        let assignment = try await APIAssignment.query(on: app.db)
            .filter(\.$publicID == id).first()!
        let setup = try await APITestSetup.find(assignment.testSetupID, on: app.db)!
        let entries = Set(listZipEntries(zipPath: setup.zipPath))
        XCTAssertTrue(entries.contains("publictest_bmi_category_01.py"))
        XCTAssertTrue(entries.contains("publictest_bmi_category_02.py"))
    }

    func testPutFamilies_rejectsInvalidFunctionName() async throws {
        let id = try await makeAssignment()
        let cookie = try await loginUser(username: "inst", password: "pw", role: "instructor", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        let bad = #"""
        [{"id":"f","name":"f","kind":"boundary_equality","functionName":"2bad",
          "paramNames":["x"],"defaults":{"tier":"public","points":1},
          "cases":[{"key":"01","label":"a","args":[1],"expected":1}]}]
        """#

        try await app.asyncTest(.PUT, "/instructor/\(id)/families", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.add(name: "x-csrf-token", value: csrf)
            req.headers.contentType = .json
            req.body = ByteBuffer(string: bad)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .unprocessableEntity)
        })
    }

    func testPutFamilies_studentCannotEdit() async throws {
        let id = try await makeAssignment()
        let studentCookie = try await loginUser(username: "stu", password: "pw", role: "student", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: studentCookie, on: app)

        try await app.asyncTest(.PUT, "/instructor/\(id)/families", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.add(name: "x-csrf-token", value: csrf)
            req.headers.contentType = .json
            req.body = ByteBuffer(string: sampleFamilyJSON())
        }, afterResponse: { res in
            // Students are blocked at the role middleware before the handler runs.
            XCTAssertTrue(res.status == .forbidden || res.status == .seeOther || res.status == .notFound,
                          "Expected forbidden/redirect for student PUT, got \(res.status)")
        })
    }

    func testPutScript_rejectsEditOfGeneratedFile() async throws {
        let id = try await makeAssignment()
        let cookie = try await loginUser(username: "inst", password: "pw", role: "instructor", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        // First, create a family so the zip has a generated file.
        try await app.asyncTest(.PUT, "/instructor/\(id)/families", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.add(name: "x-csrf-token", value: csrf)
            req.headers.contentType = .json
            req.body = ByteBuffer(string: sampleFamilyJSON())
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })

        // Attempting to edit a generated file via the raw-script endpoint must fail.
        try await app.asyncTest(
            .PUT,
            "/instructor/\(id)/scripts/publictest_bmi_category_01.py",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                req.headers.contentType = .json
                try req.content.encode(["content": "# tampered\npassed('x')\n"])
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .conflict)
                XCTAssertTrue(res.body.string.contains("Edit the family"),
                              "Expected hint to edit the family, got: \(res.body.string)")
            })

        // Deleting via the raw endpoint must also fail.
        try await app.asyncTest(
            .DELETE,
            "/instructor/\(id)/scripts/publictest_bmi_category_01.py",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .conflict)
            })
    }
}
