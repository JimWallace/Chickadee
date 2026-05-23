// Tests for ListAssignmentsTool and the dispatcher's tools/list + tools/call
// paths, backed by a real test database.

import Core
import Fluent
import Testing
import Vapor

@testable import APIServer

@Suite struct ListAssignmentsToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.read, .write]
        )
    }

    @Test func listsAssignmentsForCourseSortedByTitle() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS136", name: "Systems Programming")
            let courseID = try course.requireID()
            try await makeTestSetup(on: app, id: "setup_bit", courseID: courseID)
            try await makeTestSetup(on: app, id: "setup_app", courseID: courseID)
            try await makeTestAssignment(on: app, testSetupID: "setup_bit", courseID: courseID, title: "Bit Counting")
            try await makeTestAssignment(on: app, testSetupID: "setup_app", courseID: courseID, title: "Apportionment")

            let output = try await ListAssignmentsTool().execute(
                ListAssignmentsTool.Input(courseCode: "CS136"), context(app))
            #expect(output.courseCode == "CS136")
            #expect(output.assignments.map(\.title) == ["Apportionment", "Bit Counting"])
        }
    }

    @Test func unknownCourseThrowsToolError() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            await #expect(throws: MCPToolError.self) {
                _ = try await ListAssignmentsTool().execute(
                    ListAssignmentsTool.Input(courseCode: "NOPE"), context(app))
            }
        }
    }

    @Test func dispatcherToolsListAdvertisesRegisteredTools() async throws {
        let registry = ToolRegistry([ListAssignmentsTool().erased(), UpdateAssignmentTitleTool().erased()])
        let dispatcher = MCPDispatcher(serverInfo: MCPServerInfo(name: "t", version: "t"), tools: registry)
        let request = JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "tools/list", params: nil)
        let response = try #require(await dispatcher.dispatch(request))
        #expect(toolNames(in: response.result) == ["list_assignments", "update_assignment_title"])
    }

    @Test func dispatcherToolsCallReturnsContentAndStructured() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            try await makeTestSetup(on: app, id: "setup_tasks", courseID: courseID)
            try await makeTestAssignment(on: app, testSetupID: "setup_tasks", courseID: courseID, title: "Tasks")

            let registry = ToolRegistry([ListAssignmentsTool().erased()])
            let dispatcher = MCPDispatcher(serverInfo: MCPServerInfo(name: "t", version: "t"), tools: registry)
            let request = JSONRPCRequest(
                jsonrpc: "2.0", id: .number(2), method: "tools/call",
                params: .object([
                    "name": .string("list_assignments"),
                    "arguments": .object(["courseCode": .string("CS246")]),
                ]))
            let response = try #require(await dispatcher.dispatch(request, context: context(app)))
            let result = try #require(response.result?.objectFields)
            #expect(result["isError"] == .bool(false))
            #expect(result["content"] != nil)
            #expect(result["structuredContent"]?.objectFields?["courseCode"] == .string("CS246"))
        }
    }

    @Test func dispatcherToolsCallUnknownToolIsInvalidParams() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let dispatcher = MCPDispatcher(serverInfo: MCPServerInfo(name: "t", version: "t"))
            let request = JSONRPCRequest(
                jsonrpc: "2.0", id: .number(3), method: "tools/call",
                params: .object(["name": .string("does_not_exist")]))
            let response = try #require(await dispatcher.dispatch(request, context: context(app)))
            #expect(response.error?.code == -32_602)
        }
    }
}

private func toolNames(in result: JSONValue?) -> [String] {
    guard case .object(let object)? = result, case .array(let tools)? = object["tools"] else { return [] }
    return tools.compactMap { entry in
        guard case .object(let fields) = entry, case .string(let name)? = fields["name"] else { return nil }
        return name
    }
}

private extension JSONValue {
    var objectFields: [String: JSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }
}
