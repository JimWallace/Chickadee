// APIServer/MCP/Tools/MCPTimeLimitValidation.swift
//
// Shared bound check for the execution time-limit MCP inputs — the
// assignment-wide default (set_time_limit) and the per-script override
// (author_script / update_suite). A limit is an integer number of seconds in
// `1...600`; rejecting 0/negative/huge values with one consistent message keeps
// the three call sites honest.

import Core

/// The accepted closed range (seconds) for any execution time limit set over
/// MCP — both the assignment-wide default and a per-test override.
let mcpTimeLimitRange: ClosedRange<Int> = 1...600

/// Validates that `seconds` is an integer in `mcpTimeLimitRange`, throwing
/// `invalidArguments` otherwise. `field` names the offending argument in the
/// error message. Returns the validated value for convenient inlining.
@discardableResult
func validateTimeLimitSeconds(
    _ seconds: Int, tool: String, field: String = "seconds"
) throws -> Int {
    guard mcpTimeLimitRange.contains(seconds) else {
        throw MCPToolError.invalidArguments(
            tool: tool,
            detail:
                "\(field) must be an integer between \(mcpTimeLimitRange.lowerBound) and "
                + "\(mcpTimeLimitRange.upperBound) seconds (got \(seconds)).")
    }
    return seconds
}
