// Tests for MCP list pagination: the opaque-cursor helper itself, and the
// dispatcher's tools/list wiring (page + nextCursor walk, invalid-cursor
// rejection).  resources/list shares the same paginatedListResponse path, so
// the cursor semantics proven here apply to both list operations.

import Core
import Testing

@testable import APIServer

@Suite struct MCPListPaginationTests {
    // MARK: - Cursor helper

    @Test func cursorRoundTrips() {
        for offset in [0, 1, 100, 12345] {
            #expect(MCPListPagination.offset(fromCursor: MCPListPagination.cursor(forOffset: offset)) == offset)
        }
    }

    @Test func malformedCursorsAreRejected() {
        for cursor in ["", "!!!", "bm90LWFuLW9mZnNldA==", MCPListPagination.cursor(forOffset: 0) + "x"] {
            #expect(MCPListPagination.offset(fromCursor: cursor) == nil)
        }
    }

    @Test func pageWalksAList() throws {
        let entries = (0..<5).map { JSONValue.int($0) }

        let first = try #require(MCPListPagination.page(entries, cursor: nil, pageSize: 2))
        #expect(first.page == [.int(0), .int(1)])
        let second = try #require(MCPListPagination.page(entries, cursor: first.nextCursor, pageSize: 2))
        #expect(second.page == [.int(2), .int(3)])
        let third = try #require(MCPListPagination.page(entries, cursor: second.nextCursor, pageSize: 2))
        #expect(third.page == [.int(4)])
        #expect(third.nextCursor == nil)
    }

    @Test func staleCursorPastTheEndYieldsEmptyFinalPage() throws {
        // The list shrank between pages: a well-formed but now out-of-range
        // cursor is not an error, just an empty last page.
        let entries = [JSONValue.int(0)]
        let result = try #require(
            MCPListPagination.page(entries, cursor: MCPListPagination.cursor(forOffset: 5), pageSize: 2))
        #expect(result.page.isEmpty)
        #expect(result.nextCursor == nil)
    }

    @Test func unparseableCursorIsNil() {
        #expect(MCPListPagination.page([], cursor: "garbage") == nil)
    }

    // MARK: - Dispatcher wiring

    private static func stubTool(named name: String) -> AnyContentTool {
        AnyContentTool(
            name: name,
            title: name,
            description: "Stub tool \(name).",
            inputSchema: .object(["type": .string("object")]),
            outputSchema: nil,
            annotations: nil,
            requiredScopes: [.read],
            invoke: { _, _ in .object([:]) })
    }

    /// 150 stub tools: enough to spill into a second page at the default page
    /// size of 100.  Zero-padded names keep the registry's name-sort stable.
    private let dispatcher = MCPDispatcher(
        serverInfo: MCPServerInfo(name: "Chickadee MCP", version: "test"),
        tools: ToolRegistry((1...150).map { stubTool(named: String(format: "stub_%03d", $0)) })
    )

    private func toolsList(params: JSONValue?) async throws -> JSONRPCResponse {
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/list", params: params)
        return try #require(await dispatcher.dispatch(request))
    }

    @Test func toolsListPaginatesPastTheDefaultPageSize() async throws {
        let first = try await toolsList(params: nil)
        let (firstNames, firstCursor) = try Self.namesAndCursor(first)
        #expect(firstNames.count == 100)
        #expect(firstNames.first == "stub_001")
        let cursor = try #require(firstCursor)

        let second = try await toolsList(params: .object(["cursor": .string(cursor)]))
        let (secondNames, secondCursor) = try Self.namesAndCursor(second)
        #expect(secondNames.count == 50)
        #expect(secondNames.first == "stub_101")
        #expect(secondCursor == nil)
        #expect(Set(firstNames).isDisjoint(with: secondNames))
    }

    @Test func toolsListEntriesCarryTitles() async throws {
        // Wire-level check that the dispatcher surfaces each tool's display
        // title (this suite's stub registry is the convenient place to see a
        // full entry).
        let response = try await toolsList(params: nil)
        guard case .object(let fields)? = response.result,
            case .array(let tools)? = fields["tools"],
            case .object(let first)? = tools.first
        else {
            throw IssueRecorded("tools/list result has no first entry")
        }
        #expect(first["title"] == .string("stub_001"))
    }

    @Test func toolsListRejectsInvalidCursor() async throws {
        let response = try await toolsList(params: .object(["cursor": .string("garbage")]))
        #expect(response.error?.code == -32_602)
    }

    @Test func toolsListRejectsNonStringCursor() async throws {
        let response = try await toolsList(params: .object(["cursor": .int(7)]))
        #expect(response.error?.code == -32_602)
    }

    // MARK: - Helpers

    private static func namesAndCursor(_ response: JSONRPCResponse) throws -> ([String], String?) {
        guard case .object(let fields)? = response.result,
            case .array(let tools)? = fields["tools"]
        else {
            throw IssueRecorded("tools/list result is not an object with a tools array")
        }
        let names = tools.compactMap { entry -> String? in
            guard case .object(let tool) = entry, case .string(let name)? = tool["name"] else { return nil }
            return name
        }
        if case .string(let cursor)? = fields["nextCursor"] {
            return (names, cursor)
        }
        return (names, nil)
    }
}
