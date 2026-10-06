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

    private func context(_ app: Application, subject: String) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: subject, grantedScopes: [.read])
    }

    private func request(_ method: String, _ params: JSONValue? = nil) -> JSONRPCRequest {
        JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: method, params: params)
    }

    @Test func listRefusesAnIneligibleAccountWithItsReason() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS136", name: "Intro")
            let student = try await makeTestUser(on: app, username: "stu", role: "student")
            try await makeTestEnrollment(on: app, userID: student.requireID(), courseID: course.requireID())

            let response = try #require(
                await dispatcher().dispatch(request("resources/list"), context: context(app, subject: "stu")))
            let error = try #require(response.error)
            #expect(error.code == -32_602)
            #expect(error.message != "Failed to list resources.")
        }
    }

    @Test func readStillRefusesAnUnknownResource() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS136", name: "Intro")
            let prof = try await makeTestUser(on: app, username: "prof", role: "instructor")
            try await makeTestEnrollment(on: app, userID: prof.requireID(), courseID: course.requireID())

            let response = try #require(
                await dispatcher().dispatch(
                    request("resources/read", .object(["uri": .string("chickadee://nothing/here")])),
                    context: context(app, subject: "prof")))
            #expect(response.error?.code == -32_602)
        }
    }
}
