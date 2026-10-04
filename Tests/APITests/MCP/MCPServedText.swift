// Tests/APITests/MCP/MCPServedText.swift
//
// Every piece of text an agent can read on either MCP surface, for the
// coverage suites that scan it (#1935). Four suites used to build their own
// copy, and all four read only the content catalog, so a stale list in an
// admin tool or a doc resource was never scanned.

import Core
import Foundation

@testable import APIServer

enum MCPServedText {
    /// One tool as the coverage suites see it, from either catalog.
    struct Tool {
        let name: String
        let description: String
        let inputSchema: JSONValue
        let outputSchema: JSONValue?
    }

    /// Every tool on both surfaces: the content catalog, then the admin one.
    static let tools: [Tool] =
        MCPToolCatalog.live.all.map {
            Tool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema, outputSchema: $0.outputSchema)
        }
        + AdminMCPToolCatalog.live.all.map {
            Tool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema, outputSchema: $0.outputSchema)
        }

    /// Both servers' instructions, the doc resources' names and descriptions
    /// (and the text of the inline ones), and each tool's name, description
    /// and both schemas rendered as JSON. Schemas are included on purpose: a
    /// field `description` inside a schema is as agent-facing and as
    /// hand-written as a tool description.
    static let text: String = {
        var parts = [MCPServerInstructions.text, AdminMCPServerInstructions.text]
        for resource in MCPResourceProvider.docResources {
            parts += [resource.name, resource.description]
        }
        for resource in MCPResourceProvider.inlineDocResources {
            parts += [resource.name, resource.description, resource.text]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for tool in tools {
            parts += [tool.name, tool.description]
            for schema in [tool.inputSchema, tool.outputSchema] {
                guard let schema,
                    let data = try? encoder.encode(schema),
                    let json = String(data: data, encoding: .utf8)
                else { continue }
                parts.append(json)
            }
        }
        return parts.joined(separator: "\n")
    }()
}
