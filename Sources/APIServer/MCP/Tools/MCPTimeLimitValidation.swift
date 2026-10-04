// APIServer/MCP/Tools/MCPTimeLimitValidation.swift
//
// Shared bound check, parser and schema for the execution time-limit MCP
// inputs: the assignment-wide default (set_time_limit) and the per-test
// override that author_script, update_suite, create_pattern_family,
// update_pattern_family and author_notebook_check take. A limit is an integer
// number of seconds in `1...600`; an override also takes 0, which clears it.

import Core

/// The accepted closed range (seconds) for any execution time limit set over
/// MCP — both the assignment-wide default and a per-test override.
let mcpTimeLimitRange: ClosedRange<Int> = 1...600

/// Validates that `seconds` is an integer in `mcpTimeLimitRange`, throwing
/// `invalidArguments` otherwise. `field` names the offending argument in the
/// error message. Returns the validated value for convenient inlining.
@discardableResult
func validateTimeLimitSeconds(
    _ seconds: Int, field: String = "seconds"
) throws -> Int {
    guard mcpTimeLimitRange.contains(seconds) else {
        throw MCPToolError.invalidArguments(
            detail:
                "\(field) must be an integer between \(mcpTimeLimitRange.lowerBound) and "
                + "\(mcpTimeLimitRange.upperBound) seconds (got \(seconds)).")
    }
    return seconds
}

/// `"1–600"`: the accepted range as prose states it, so no description types
/// the bounds by hand (#1941).
let mcpTimeLimitRangeText = "\(mcpTimeLimitRange.lowerBound)–\(mcpTimeLimitRange.upperBound)"

/// What an MCP caller asked of a per-test time-limit override.
enum TimeLimitOverrideEdit: Equatable, Sendable {
    /// The field was omitted.
    case unchanged
    /// The caller passed 0: drop the override and inherit the default.
    case clear
    /// The caller passed a value in `mcpTimeLimitRange`.
    case set(Int)

    /// The override to store, given the one stored now. A create path passes
    /// nil, so an omitted field and 0 both mean "no override".
    func applied(to existing: Int?) -> Int? {
        switch self {
        case .unchanged: return existing
        case .clear: return nil
        case .set(let seconds): return seconds
        }
    }
}

/// Parses a per-test time-limit override. Omitted leaves it unchanged, 0
/// clears it, and any other value must be in `mcpTimeLimitRange`. The one
/// parser for every tool that takes an override (#1941).
func parseTimeLimitOverride(_ raw: Int?, field: String) throws -> TimeLimitOverrideEdit {
    guard let raw else { return .unchanged }
    guard raw != 0 else { return .clear }
    return .set(try validateTimeLimitSeconds(raw, field: field))
}

extension MCPSchema {
    /// The schema for a per-test time-limit override: an integer from 0 (which
    /// clears the override) to the top of `mcpTimeLimitRange`. The bounds come
    /// from the constant; `description` is the field's own sentence.
    static func timeLimit(_ description: String) -> JSONValue {
        .object([
            "type": .string("integer"),
            "minimum": .int(0),
            "maximum": .int(mcpTimeLimitRange.upperBound),
            "description": .string(description),
        ])
    }
}
