// APIServer/MCP/Tools/MCPTierParsing.swift
//
// Shared tier parsing for the suite/pattern-family MCP tools, which each
// carried an identical `String? -> TestTier?` helper differing only in the
// argument name reported on failure.

import Core

/// Parses an optional tier string into a `TestTier`, returning nil for a nil
/// input and throwing `invalidArguments` for an unrecognized value. `field`
/// names the offending argument in the error message (e.g. "tier",
/// "defaultTier").
func parseOptionalTier(_ raw: String?, tool: String, field: String = "tier") throws -> TestTier? {
    guard let raw else { return nil }
    guard let tier = TestTier(rawValue: raw) else {
        throw MCPToolError.invalidArguments(
            tool: tool, detail: "\(field) must be one of: \(MCPTierProse.oneOfList).")
    }
    return tier
}
