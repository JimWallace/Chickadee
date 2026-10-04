// APIServer/MCP/Transport/MCPToolRegistry.swift
//
// The name-keyed tool registry, shared by the content surface
// (`ToolRegistry`) and the admin surface (`DiagnosticToolRegistry`). The two
// used to be separate structs that differed only in their element type
// (#1944).

/// Name-keyed registry of one MCP surface's type-erased tools.
struct MCPToolRegistry<Tool: MCPListableTool & Sendable>: Sendable {
    private let toolsByName: [String: Tool]

    /// When two tools share a name, the first one wins.
    init(_ tools: [Tool]) {
        toolsByName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { existing, _ in existing })
    }

    /// All registered tools, sorted by name for stable `tools/list` output.
    var all: [Tool] {
        toolsByName.values.sorted { $0.name < $1.name }
    }

    func tool(named name: String) -> Tool? {
        toolsByName[name]
    }
}
