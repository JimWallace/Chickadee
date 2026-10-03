// Tests/APITests/MCP/MCPEnumProseTests.swift
//
// `MCPEnumProse` renders every agent-facing enum list from `allCases` (#1938).
// The prose modules and four tool schemas now delegate to it, so these tests
// pin each rendering once, on an enum whose cases are stable.

import Core
import Testing

@testable import APIServer

@Suite struct MCPEnumProseTests {
    private typealias Visibility = MCPEnumProse<AssignmentVisibility>

    @Test func renderingsFollowDeclarationOrder() {
        #expect(Visibility.tokens == ["closed", "preview", "open"])
        #expect(Visibility.slashAlternatives == "closed/preview/open")
        #expect(Visibility.slashSeparated == "closed / preview / open")
        #expect(Visibility.oneOfList == "closed, preview, open")
        #expect(Visibility.orList == "closed, preview or open")
        #expect(Visibility.quotedOrList == "\"closed\", \"preview\" or \"open\"")
        #expect(Visibility.quotedUnion == "\"closed\" | \"preview\" | \"open\"")
        #expect(Visibility.jsonEnum == .array([.string("closed"), .string("preview"), .string("open")]))
    }

    @Test func schemaRestrictsAStringToTheCases() {
        #expect(
            Visibility.schema("Who can see it.")
                == .object([
                    "type": .string("string"),
                    "enum": Visibility.jsonEnum,
                    "description": .string("Who can see it."),
                ]))
    }

    @Test func parseAcceptsACase() throws {
        #expect(try Visibility.parse("preview", tool: "t", field: "visibility") == .preview)
        #expect(try Visibility.parseOptional(nil, tool: "t", field: "visibility") == nil)
        #expect(try Visibility.parseOptional("open", tool: "t", field: "visibility") == .open)
    }

    @Test func parseRefusesAnUnknownTokenWithTheLegalValues() {
        #expect {
            try Visibility.parse("public", tool: "update_assignment", field: "visibility")
        } throws: { error in
            guard case MCPToolError.invalidArguments(let tool, let detail) = error else { return false }
            return tool == "update_assignment"
                && detail == "visibility must be one of: closed, preview, open."
        }
    }

    /// The enums Core gained `CaseIterable` for, so their schemas could be derived.
    @Test func theNewlyDerivedSchemasCoverEveryCase() {
        #expect(MCPEnumProse<GradingMode>.tokens == ["browser", "worker"])
        #expect(MCPEnumProse<SubmissionMode>.tokens == ["notebook", "uploadOnly"])
        #expect(MCPEnumProse<ColumnMatchMode>.tokens == ["exact", "superset"])
        #expect(MCPEnumProse<ConditionMatch>.tokens == ["all", "any"])
    }
}
