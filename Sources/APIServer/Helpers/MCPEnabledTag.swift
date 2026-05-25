// APIServer/Helpers/MCPEnabledTag.swift
//
// Leaf tag that reports whether the content-authoring MCP endpoint is mounted
// (`MCP_MODE` is read_only or read_write). Used to hide the admin "MCP" nav tab
// entirely when MCP is off, e.g.:
//   #if(mcpEnabled()):<a class="admin-tab" href="/admin/mcp">MCP</a>#endif
//
// Boot-fixed app-global (like the app version / idle-timeout tags), so a Leaf
// tag reading it once per render is the right fit — no per-context plumbing.

import Leaf
import Vapor

struct MCPEnabledTag: LeafTag {
    func render(_ ctx: LeafContext) throws -> LeafData {
        try ctx.requireParameterCount(0)
        guard let req = ctx.request else { return .bool(false) }
        return .bool(req.application.appConfig.mcp.mode.isMounted)
    }
}
