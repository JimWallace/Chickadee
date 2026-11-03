// Tests/APITests/Grading/BrowserRunnerManifestSeedGateTests.swift
//
// The browser-runner manifest and seed endpoints serve a student only a
// browser-graded setup, as the zip download does (#2763). Staff keep access.
// The seed of a setup with no assignment stays an empty answer for everyone.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class BrowserRunnerManifestSeedGateTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-brmsgate")
    }

    // MARK: - Helpers

    /// A setup in an `.auto` course, so a student who signs in is enrolled.
    /// With `withAssignment`, an open assignment owns it.
    private func insertSetup(manifest: String, withAssignment: Bool = true) async throws -> String {
        let setupID = "setup_\(UUID().uuidString.lowercased().prefix(8))"
        let course = APICourse(code: "BRM101", name: "Browser Gate Course", enrollmentMode: .auto)
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: manifest, withNotebook: false)
        if withAssignment {
            let assignment = APIAssignment(
                testSetupID: setupID, title: "Gate Assignment", dueAt: nil, isOpen: true, courseID: courseID)
            try await assignment.save(on: app.db)
        }
        return setupID
    }

    private func get(_ endpoint: String, _ setupID: String, cookie: String) async throws -> (HTTPStatus, Data) {
        var status = HTTPStatus.internalServerError
        var body = Data()
        try await app.asyncTest(
            .GET, "/api/v1/browser-runner/testsetups/\(setupID)/\(endpoint)",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                status = res.status
                body = Data(res.body.readableBytesView)
            })
        return (status, body)
    }

    private func staffCookie() async throws -> String {
        let cookie = try await loginUser(username: "gateprof", password: "pass", role: "instructor", on: app)
        try await promoteToInstructor("gateprof", on: app)
        return cookie
    }

    /// A personalized manifest, so a seed answer carries resolved inputs.
    private func manifest(gradingMode: String) -> String {
        """
        {"schemaVersion":1,"gradingMode":"\(gradingMode)","testSuites":\
        [{"tier":"secret","script":"test_secret.py"}],"timeLimitSeconds":10,\
        "globalExpressions":[{"name":"answer","expression":"7 * 6"}]}
        """
    }

    // MARK: - Manifest

    @Test func studentIsRefusedTheManifestOfAWorkerGradedSetup() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetup(manifest: manifest(gradingMode: "worker"))
            let cookie = try await loginAsStudent("gatestudent", on: app)
            let (status, body) = try await get("manifest", setupID, cookie: cookie)
            #expect(status == .forbidden)
            #expect(String(bytes: body, encoding: .utf8)?.contains("test_secret.py") == false)
        }
    }

    @Test func studentReadsTheManifestOfABrowserGradedSetup() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetup(manifest: manifest(gradingMode: "browser"))
            let cookie = try await loginAsStudent("gatestudent", on: app)
            let (status, _) = try await get("manifest", setupID, cookie: cookie)
            #expect(status == .ok)
        }
    }

    @Test func studentIsRefusedTheManifestWhenItDoesNotDecode() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetup(manifest: "{ not json")
            let cookie = try await loginAsStudent("gatestudent", on: app)
            let (status, _) = try await get("manifest", setupID, cookie: cookie)
            #expect(status == .forbidden)
        }
    }

    @Test func staffReadTheManifestOfAWorkerGradedSetup() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetup(manifest: manifest(gradingMode: "worker"))
            let cookie = try await staffCookie()
            let (status, _) = try await get("manifest", setupID, cookie: cookie)
            #expect(status == .ok)
        }
    }

    // MARK: - Seed

    @Test func studentIsRefusedTheSeedOfAWorkerGradedSetup() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetup(manifest: manifest(gradingMode: "worker"))
            let cookie = try await loginAsStudent("gatestudent", on: app)
            let (status, body) = try await get("seed", setupID, cookie: cookie)
            #expect(status == .forbidden)
            #expect(String(bytes: body, encoding: .utf8)?.contains("personalizedInputs") == false)
        }
    }

    @Test func studentReadsTheSeedOfABrowserGradedSetup() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetup(manifest: manifest(gradingMode: "browser"))
            let cookie = try await loginAsStudent("gatestudent", on: app)
            let (status, body) = try await get("seed", setupID, cookie: cookie)
            #expect(status == .ok)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["seed"] is String)
        }
    }

    @Test func staffReadTheSeedOfAWorkerGradedSetup() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetup(manifest: manifest(gradingMode: "worker"))
            let cookie = try await staffCookie()
            let (status, body) = try await get("seed", setupID, cookie: cookie)
            #expect(status == .ok)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["seed"] is String)
        }
    }

    /// With no assignment the seed answer is empty, so it is not gated: the
    /// behaviour before #2763 holds.
    @Test func seedOfASetupWithNoAssignmentStaysEmptyForAStudent() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetup(manifest: manifest(gradingMode: "worker"), withAssignment: false)
            let cookie = try await loginAsStudent("gatestudent", on: app)
            let (status, body) = try await get("seed", setupID, cookie: cookie)
            #expect(status == .ok)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["seed"] as? String == nil)
        }
    }
}
