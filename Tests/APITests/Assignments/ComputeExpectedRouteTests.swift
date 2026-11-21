// Tests/APITests/Assignments/ComputeExpectedRouteTests.swift
//
// `POST /instructor/:assignmentID/compute-expected` calls the reference
// solution in the assignment's own language and returns the value as a
// literal (`PublishedAssignmentRoutes+ComputeExpected.swift`).
//
// What this suite pins:
//   * the refusals that answer without spawning anything: a manifest that is
//     not JSON, an assignment that declares no language, and stdout capture in
//     a language with no single-expression spelling for it;
//   * a real Python call against `solution.py` in the setup's shared support
//     directory, which renders the return value as a Python literal;
//   * a call to a function that does not exist, in every language, which comes
//     back as `ok: false` with the driver's error and never as a value. That
//     holds whether or not the interpreter is installed on the host: a missing
//     interpreter fails the spawn, and a present one fails the call.
//
// The route's role floor (TA) is pinned by `RouteAuthorizationMatrixTests`,
// so it is not repeated here.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import NIOFoundationCompat
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class ComputeExpectedRouteTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-compute-expected")
    }

    private struct Session {
        let cookie: String
        let csrf: String
    }

    private struct Body: Encodable {
        let functionName: String
        let args: [JSONValue]
        let captureStdout: Bool?
    }

    private typealias Reply = PublishedAssignmentRoutes.ComputeExpectedResponse

    private static func manifest(language: AssignmentLanguage?) -> String {
        guard let language else {
            return #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#
        }
        return #"{"schemaVersion":1,"language":"\#(language.rawValue)","languageDeclared":true,"#
            + #""testSuites":[],"timeLimitSeconds":10}"#
    }

    /// A TEST101 assignment on `manifest`, and a TA of TEST101 signed in with a
    /// CSRF token for the session. The token is read from the edit page of a
    /// second, well-formed assignment, so a broken manifest under test does
    /// not stop the sign-in.
    private func scenario(
        setupID: String, manifest: String
    ) async throws -> (assignment: APIAssignment, session: Session) {
        let scenario = try await TestScenario.make(
            on: app, setupID: setupID, manifest: manifest, withNotebook: false)
        try await makeTestSetup(
            on: app, id: setupID + "_csrf", courseID: scenario.courseID,
            manifest: Self.manifest(language: .python), withNotebook: false)
        let tokenSource = try await makeTestAssignment(
            on: app, testSetupID: setupID + "_csrf", courseID: scenario.courseID, title: "Token source")
        let username = "ce_ta_\(setupID)"
        let cookie = try await loginUser(username: username, password: "pw", role: "user", on: app)
        try await enrollInTestCourse(username: username, role: .ta, on: app)
        let (csrf, sessionCookie) = try await csrfFields(
            for: "/instructor/\(tokenSource.publicID)/edit", cookie: cookie, on: app)
        try #require(!csrf.isEmpty, "the edit page must carry a CSRF token")
        return (scenario.assignment, Session(cookie: sessionCookie, csrf: csrf))
    }

    private func post(
        _ assignment: APIAssignment, _ session: Session, _ body: Body,
        expecting status: HTTPResponseStatus = .ok
    ) async throws -> Reply? {
        var reply: Reply?
        let data = try JSONEncoder().encode(body)
        try await app.asyncTest(
            .POST, "/instructor/\(assignment.publicID)/compute-expected",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: session.cookie)
                req.headers.add(name: "x-csrf-token", value: session.csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(data: data)
            },
            afterResponse: { res in
                #expect(res.status == status, "\(res.body.string)")
                if res.status == .ok { reply = try res.content.decode(Reply.self) }
            })
        return reply
    }

    // MARK: - Refusals that spawn nothing

    @Test func aManifestThatIsNotJSONIsABadRequest() async throws {
        try await withApp(app) { _ in
            let (assignment, session) = try await scenario(setupID: "ce_badjson", manifest: "{not json")
            let reply = try await post(
                assignment, session, Body(functionName: "f", args: [], captureStdout: nil),
                expecting: .badRequest)
            #expect(reply == nil)
        }
    }

    @Test func anAssignmentWithNoLanguageHasNoSolutionToCall() async throws {
        try await withApp(app) { _ in
            let (assignment, session) = try await scenario(
                setupID: "ce_nolang", manifest: Self.manifest(language: nil))
            let reply = try #require(
                try await post(assignment, session, Body(functionName: "f", args: [.int(1)], captureStdout: nil)))
            #expect(!reply.ok)
            #expect(reply.rendered == nil)
            #expect(reply.error == nil)
            #expect(reply.unsupportedReason?.contains("declares no language") == true)
        }
    }

    /// Python, Lua, Racket, C++ and Java have no one-expression spelling for
    /// capturing printed output. The route says so instead of computing a
    /// value some other way.
    @Test(arguments: [AssignmentLanguage.python, .lua, .racket, .cpp, .java])
    func stdoutCaptureWithoutASpellingIsRefused(_ language: AssignmentLanguage) async throws {
        try await withApp(app) { _ in
            let (assignment, session) = try await scenario(
                setupID: "ce_cap_\(language.rawValue)", manifest: Self.manifest(language: language))
            let reply = try #require(
                try await post(
                    assignment, session, Body(functionName: "show", args: [.int(1)], captureStdout: true)))
            #expect(!reply.ok)
            #expect(reply.rendered == nil)
            #expect(reply.error == nil)
            let reason = try #require(reply.unsupportedReason)
            #expect(reason.contains("printed output"))
            #expect(reason.contains(language.displayName))
        }
    }

    // MARK: - Calls that run the driver

    @Test(.requiresPython3) func aPythonSolutionCallRendersThePythonLiteral() async throws {
        try await withApp(app) { _ in
            let (assignment, session) = try await scenario(
                setupID: "ce_py_ok", manifest: Self.manifest(language: .python))
            try writeSharedSupportFile(
                "solution.py", "def scale(xs, k):\n    return [x * k for x in xs]\n", for: assignment)
            let reply = try #require(
                try await post(
                    assignment, session,
                    Body(
                        functionName: "scale", args: [.array([.int(1), .int(2)]), .int(3)],
                        captureStdout: false)))
            #expect(reply.ok)
            #expect(reply.rendered == "[3, 6]")
            #expect(reply.error == nil)
            #expect(reply.unsupportedReason == nil)
        }
    }

    /// Every language, and in R and Octave both with and without stdout
    /// capture: a function the solution does not define is an error the
    /// instructor reads, never a value in the Expected cell.
    @Test(arguments: [
        (AssignmentLanguage.python, false), (.r, false), (.r, true), (.octave, false), (.octave, true),
        (.lua, false), (.racket, false), (.cpp, false), (.java, false),
    ])
    func anUndefinedFunctionIsReportedAsAnError(_ language: AssignmentLanguage, _ capture: Bool) async throws {
        try await withApp(app) { _ in
            let (assignment, session) = try await scenario(
                setupID: "ce_undef_\(language.rawValue)_\(capture)", manifest: Self.manifest(language: language))
            let name = language == .java ? "NoSuchClass.noSuchMethod" : "no_such_function"
            let reply = try #require(
                try await post(assignment, session, Body(functionName: name, args: [.int(1)], captureStdout: capture)))
            #expect(!reply.ok)
            #expect(reply.rendered == nil)
            #expect(reply.unsupportedReason == nil)
            let error = try #require(reply.error)
            #expect(!error.isEmpty)
        }
    }

    // MARK: - Helpers

    /// Writes `name` into the setup's `shared/<testSetupID>/` support
    /// directory, the working directory the evaluator spawns in.
    private func writeSharedSupportFile(_ name: String, _ contents: String, for assignment: APIAssignment) throws {
        let directory = URL(fileURLWithPath: app.testSetupsDirectory)
            .appendingPathComponent("shared").appendingPathComponent(assignment.testSetupID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
