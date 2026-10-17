// Tests/APITests/Assignments/SuiteAnchorRoutesTests.swift
//
// Pinning a test to a cell (notebook views NB7): a suite rewrite keeps each
// script's pin, and PUT /instructor/:id/suite-anchor pins and clears a
// hand-written test but refuses a generated one.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct SuiteAnchorRoutesTests {

    private let manifest = """
        {"schemaVersion":1,"gradingMode":"worker","language":"python","requiredFiles":[],\
        "testSuites":[{"tier":"public","script":"test_a.py"},\
        {"tier":"public","script":"check_c1.py","generatedByCheck":"c1"}],"timeLimitSeconds":10}
        """

    @Test func aSuiteRewriteKeepsEachScriptsPin() throws {
        let props = TestProperties(
            testSuites: [
                TestSuiteEntry(tier: .pub, script: "test_a.py", anchor: "summary"),
                TestSuiteEntry(tier: .pub, script: "test_b.py", anchor: "other"),
            ], language: .python)
        // The editor sends rows with no anchor, and drops test_b.
        let json = try makeWorkerManifestJSON(
            preserving: props,
            testSuites: [
                ConfiguredSuiteEntry(
                    script: "test_a.py", tier: "public", order: 1, dependsOn: [], points: 2, displayName: nil)
            ],
            language: .python)
        let next = try #require(decodeManifest(fromJSON: json))
        #expect(next.testSuites.map(\.script) == ["test_a.py"])
        #expect(next.testSuites.map(\.anchor) == ["summary"])
        #expect(next.testSuites.map(\.points) == [2])
    }

    private func put(
        _ body: String, assignmentID: String, cookie: String, on app: Application
    ) async throws -> (HTTPStatus, String) {
        var status = HTTPStatus.imATeapot
        var text = ""
        let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
        try await app.asyncTest(
            .PUT, "/instructor/\(assignmentID)/suite-anchor",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: body)
            },
            afterResponse: { res in
                status = res.status
                text = res.body.string
            })
        return (status, text)
    }

    private func storedAnchors(_ setupID: String, on app: Application) async throws -> [String?] {
        let setup = try #require(try await APITestSetup.find(setupID, on: app.db))
        return try #require(decodeManifest(fromJSON: setup.manifest)).testSuites.map(\.anchor)
    }

    @Test func staffPinAndClearAHandWrittenTest() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await arInsertSetup(id: "setup_pin", manifest: manifest, on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_pin", title: "Pin Lab", isOpen: false, on: app)

            var (status, _) = try await put(
                #"{"script":"test_a.py","anchor":"average_heart_rate"}"#, assignmentID: assignment.publicID,
                cookie: cookie, on: app)
            #expect(status == .ok)
            #expect(try await storedAnchors("setup_pin", on: app) == ["average_heart_rate", nil])

            (status, _) = try await put(
                #"{"script":"test_a.py","anchor":null}"#, assignmentID: assignment.publicID, cookie: cookie, on: app)
            #expect(status == .ok)
            #expect(try await storedAnchors("setup_pin", on: app) == [nil, nil])
        }
    }

    @Test func aGeneratedOrUnknownTestIsRefused() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await arInsertSetup(id: "setup_pin_gen", manifest: manifest, on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_pin_gen", title: "Pin Lab", isOpen: false, on: app)

            let (generated, why) = try await put(
                #"{"script":"check_c1.py","anchor":"x"}"#, assignmentID: assignment.publicID, cookie: cookie, on: app)
            #expect(generated != .ok)
            #expect(why.contains("generated"))
            let (unknown, _) = try await put(
                #"{"script":"nope.py","anchor":"x"}"#, assignmentID: assignment.publicID, cookie: cookie, on: app)
            #expect(unknown != .ok)
            #expect(try await storedAnchors("setup_pin_gen", on: app) == [nil, nil])
        }
    }

    @Test func aStudentCannotPin() async throws {
        try await withAssignmentRoutesApp { app in
            try await arInsertSetup(id: "setup_pin_s", manifest: manifest, on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_pin_s", title: "Pin Lab", isOpen: true, on: app)
            let cookie = try await arLoginAsStudent(on: app)
            let (status, _) = try await put(
                #"{"script":"test_a.py","anchor":"x"}"#, assignmentID: assignment.publicID, cookie: cookie, on: app)
            #expect(status != .ok)
            #expect(try await storedAnchors("setup_pin_s", on: app) == [nil, nil])
        }
    }
}
