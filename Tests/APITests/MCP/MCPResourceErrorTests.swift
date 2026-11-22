// Tests/APITests/MCP/MCPResourceErrorTests.swift
//
// resources/list and resources/read map a refusal to `invalidParams` with its
// reason, as the tools path does, instead of one opaque -32603 (#2340).

import Core
import Fluent
import Testing
import Vapor

@testable import APIServer

@Suite struct MCPResourceErrorTests {
    private func dispatcher() -> MCPDispatcher {
        MCPDispatcher(serverInfo: MCPServerInfo(name: "t", version: "t"))
    }

    private func request(_ method: String, _ params: JSONValue? = nil) -> JSONRPCRequest {
        JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: method, params: params)
    }

    @Test func listRefusesAnIneligibleAccountWithItsReason() async throws {
        try await withTestApp { app in
            let course = try await makeTestCourse(on: app, code: "CS136", name: "Intro")
            let student = try await makeTestUser(on: app, username: "stu", role: "student")
            try await makeTestEnrollment(on: app, userID: student.requireID(), courseID: course.requireID())

            let response = try #require(
                await dispatcher().dispatch(
                    request("resources/list"), context: mcpContext(app, subject: "stu", scopes: [.read])))
            let error = try #require(response.error)
            #expect(error.code == -32_602)
            #expect(error.message != "Failed to list resources.")
        }
    }

    /// Both resource methods need the read scope. A write-only grant is
    /// refused before any lookup, with the scope it lacks.
    @Test(arguments: ["resources/list", "resources/read"])
    func aWriteOnlyGrantIsRefusedForInsufficientScope(method: String) async throws {
        try await withTestApp { app in
            let course = try await makeTestCourse(on: app, code: "CS136", name: "Intro")
            let prof = try await makeTestUser(on: app, username: "prof", role: "instructor")
            try await makeTestEnrollment(on: app, userID: prof.requireID(), courseID: course.requireID())

            let response = try #require(
                await dispatcher().dispatch(
                    request(method, .object(["uri": .string("chickadee://nothing/here")])),
                    context: mcpContext(app, subject: "prof", scopes: [.write])))
            let error = try #require(response.error)
            #expect(error.code == JSONRPCError.insufficientScopeCode)
            #expect(error.data == .string(ContentScope.read.rawValue))
        }
    }

    @Test func readWithoutAURIIsInvalidParams() async throws {
        try await withTestApp { app in
            let course = try await makeTestCourse(on: app, code: "CS136", name: "Intro")
            let prof = try await makeTestUser(on: app, username: "prof", role: "instructor")
            try await makeTestEnrollment(on: app, userID: prof.requireID(), courseID: course.requireID())

            let response = try #require(
                await dispatcher().dispatch(
                    request("resources/read"), context: mcpContext(app, subject: "prof", scopes: [.read])))
            let error = try #require(response.error)
            #expect(error.code == -32_602)
            #expect(error.message == "Invalid params: resources/read requires a \"uri\".")
        }
    }

    /// The listing an eligible account gets through the dispatcher is the
    /// provider's listing, in the paginated `resources` envelope.
    @Test func listAnswersAnEnrolledInstructorWithTheirResources() async throws {
        try await withTestApp { app in
            let course = try await makeTestCourse(on: app, code: "CS136", name: "Intro")
            let courseID = try course.requireID()
            let prof = try await makeTestUser(on: app, username: "prof", role: "instructor")
            try await makeTestEnrollment(on: app, userID: prof.requireID(), courseID: courseID)
            try await makeTestSetup(on: app, id: "setup_r", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_r", courseID: courseID, title: "Lab")

            let response = try #require(
                await dispatcher().dispatch(
                    request("resources/list"), context: mcpContext(app, subject: "prof", scopes: [.read])))
            #expect(response.error == nil)
            let entries: [JSONValue]? =
                if case .object(let fields)? = response.result, case .array(let list)? = fields["resources"] {
                    list
                } else {
                    nil
                }
            let uris = try #require(entries).compactMap { entry -> String? in
                guard case .object(let fields) = entry, case .string(let uri)? = fields["uri"] else { return nil }
                return uri
            }
            #expect(uris.contains(MCPResourceProvider.manifestURI(publicID: assignment.publicID)))
        }
    }

    @Test func readStillRefusesAnUnknownResource() async throws {
        try await withTestApp { app in
            let course = try await makeTestCourse(on: app, code: "CS136", name: "Intro")
            let prof = try await makeTestUser(on: app, username: "prof", role: "instructor")
            try await makeTestEnrollment(on: app, userID: prof.requireID(), courseID: course.requireID())

            let response = try #require(
                await dispatcher().dispatch(
                    request("resources/read", .object(["uri": .string("chickadee://nothing/here")])),
                    context: mcpContext(app, subject: "prof", scopes: [.read])))
            #expect(response.error?.code == -32_602)
        }
    }
}
