// Tests/APITests/Grading/BrowserRunnerDownloadGateTests.swift
//
// The browser-runner setup download serves a student only a browser-graded
// setup, and fails closed when the manifest does not decode (#2763). Staff keep
// access to every setup. The grader-only filter streams a copy from disk.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class BrowserRunnerDownloadGateTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-brgate")
    }

    // MARK: - Helpers

    /// A setup in an `.auto` course with an open assignment, so a student who
    /// signs in is enrolled and passes the open gate.
    private func insertOpenSetup(manifest: String) async throws -> APITestSetup {
        let setupID = "setup_\(UUID().uuidString.lowercased().prefix(8))"
        let course = APICourse(code: "BRG101", name: "Browser Gate Course", enrollmentMode: .auto)
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        let setup = try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: manifest, withNotebook: false)
        let assignment = APIAssignment(
            testSetupID: setupID, title: "Gate Assignment", dueAt: nil, isOpen: true, courseID: courseID)
        try await assignment.save(on: app.db)
        return setup
    }

    private func download(_ setupID: String, cookie: String) async throws -> (HTTPStatus, Data) {
        var status = HTTPStatus.internalServerError
        var body = Data()
        try await app.asyncTest(
            .GET, "/api/v1/browser-runner/testsetups/\(setupID)/download",
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

    private func manifest(gradingMode: String, extra: String = "") -> String {
        """
        {"schemaVersion":1,"gradingMode":"\(gradingMode)","requiredFiles":[],\
        "testSuites":[{"tier":"public","script":"test_public.py"},\
        {"tier":"secret","script":"test_secret.py"}],"timeLimitSeconds":10,"makefile":null\(extra)}
        """
    }

    // MARK: - Grading mode

    @Test func studentIsRefusedTheSetupOfAWorkerGradedAssignment() async throws {
        try await withApp(app) { _ in
            let setup = try await insertOpenSetup(manifest: manifest(gradingMode: "worker"))
            let cookie = try await loginAsStudent("gatestudent", on: app)
            let (status, _) = try await download(try setup.requireID(), cookie: cookie)
            #expect(status == .forbidden)
        }
    }

    @Test func studentDownloadsTheSetupOfABrowserGradedAssignment() async throws {
        try await withApp(app) { _ in
            let setup = try await insertOpenSetup(manifest: manifest(gradingMode: "browser"))
            let cookie = try await loginAsStudent("gatestudent", on: app)
            let (status, _) = try await download(try setup.requireID(), cookie: cookie)
            #expect(status == .ok)
        }
    }

    /// An upload-only assignment grades on the worker whatever mode it stores
    /// (`effectiveGradingMode`), so its setup is refused too.
    @Test func studentIsRefusedAnUploadOnlySetupThatStoresBrowser() async throws {
        try await withApp(app) { _ in
            let setup = try await insertOpenSetup(
                manifest: manifest(gradingMode: "browser", extra: #","submissionMode":"uploadOnly""#))
            let decoded = try #require(setup.decodedManifest())
            #expect(decoded.effectiveGradingMode == .worker)
            let cookie = try await loginAsStudent("gatestudent", on: app)
            let (status, _) = try await download(try setup.requireID(), cookie: cookie)
            #expect(status == .forbidden)
        }
    }

    @Test func staffDownloadTheSetupOfAWorkerGradedAssignment() async throws {
        try await withApp(app) { _ in
            let setup = try await insertOpenSetup(manifest: manifest(gradingMode: "worker"))
            let cookie = try await staffCookie()
            let (status, _) = try await download(try setup.requireID(), cookie: cookie)
            #expect(status == .ok)
        }
    }

    // MARK: - Manifest that does not decode

    @Test func studentIsRefusedWhenTheManifestDoesNotDecode() async throws {
        try await withApp(app) { _ in
            let setup = try await insertOpenSetup(manifest: "{ not json")
            #expect(setup.decodedManifest() == nil)
            let cookie = try await loginAsStudent("gatestudent", on: app)
            let (status, _) = try await download(try setup.requireID(), cookie: cookie)
            #expect(status == .forbidden)
        }
    }

    @Test func staffDownloadWhenTheManifestDoesNotDecode() async throws {
        try await withApp(app) { _ in
            let setup = try await insertOpenSetup(manifest: "{ not json")
            let cookie = try await staffCookie()
            let (status, _) = try await download(try setup.requireID(), cookie: cookie)
            #expect(status == .ok)
        }
    }

    // MARK: - Grader-only filter

    /// A browser-graded setup whose zip holds a test script and a grader-only
    /// file. Returns the setup and a staging directory the caller removes.
    private func insertGraderOnlySetup() async throws -> (APITestSetup, URL) {
        let setup = try await insertOpenSetup(
            manifest: manifest(gradingMode: "browser", extra: #","graderOnlyFiles":["answers.csv"]"#))
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("brgate-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("print(1)\n".utf8).write(to: staging.appendingPathComponent("test_public.py"))
        try Data("x,y\n1,2\n".utf8).write(to: staging.appendingPathComponent("answers.csv"))
        try await repackZipFromDirectory(zipPath: setup.zipPath, sourceDir: staging)
        return (setup, staging)
    }

    /// The filtered copies this handler leaves in the temporary directory.
    private func leftoverFilteredCopies() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("ck-browser-zip-") }
    }

    @Test func filteredDownloadOmitsGraderOnlyFilesAndKeepsTheRest() async throws {
        try await withApp(app) { _ in
            let (setup, staging) = try await insertGraderOnlySetup()
            defer { try? FileManager.default.removeItem(at: staging) }

            let cookie = try await loginAsStudent("gatestudent", on: app)
            let (status, body) = try await download(try setup.requireID(), cookie: cookie)
            #expect(status == .ok)

            let received = staging.appendingPathComponent("received.zip").path
            try body.write(to: URL(fileURLWithPath: received))
            let entries = await listZipEntries(zipPath: received)
            #expect(entries.contains("test_public.py"))
            #expect(!entries.contains("answers.csv"))

            // The stored zip is untouched: only the copy was filtered.
            let stored = await listZipEntries(zipPath: setup.zipPath)
            #expect(stored.contains("answers.csv"))
        }
    }

    /// The filtered copy is removed once it has streamed, and a conditional
    /// request still gets the whole body: a 304 would skip the cleanup.
    @Test func filteredDownloadRemovesItsCopyAndIgnoresConditionalHeaders() async throws {
        try await withApp(app) { _ in
            let (setup, staging) = try await insertGraderOnlySetup()
            defer { try? FileManager.default.removeItem(at: staging) }
            let cookie = try await loginAsStudent("gatestudent", on: app)
            let before = Set(try leftoverFilteredCopies())

            var status = HTTPStatus.internalServerError
            try await app.asyncTest(
                .GET, "/api/v1/browser-runner/testsetups/\(try setup.requireID())/download",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    req.headers.add(name: .ifNoneMatch, value: "*")
                    req.headers.add(name: .range, value: "bytes=0-3")
                },
                afterResponse: { res in status = res.status })
            #expect(status == .ok)

            // The completion hook runs after the body is written; give it a
            // moment rather than racing it.
            var leftover = Set(try leftoverFilteredCopies()).subtracting(before)
            for _ in 0..<50 where !leftover.isEmpty {
                try await Task.sleep(for: .milliseconds(20))
                leftover = Set(try leftoverFilteredCopies()).subtracting(before)
            }
            #expect(leftover.isEmpty)
        }
    }
}
