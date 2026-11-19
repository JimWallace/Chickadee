// APIServer/MCP/Protocol/MCPAssignmentTypeCapability.swift
//
// One declared assignment type and its rules, as `get_server_info` reports
// them (docs/assignment-types.md). Every field is read from the
// `AssignmentType` property that the code enforces, and `rules` is the prose
// the web pages show (`AssignmentTypeRules`), so the report cannot disagree
// with what a save refuses.

import Core

struct MCPAssignmentTypeCapability: Encodable, Sendable, Equatable {
    /// The wire token (`AssignmentType` raw value).
    let name: String
    let displayName: String
    /// The grading mode the type sets on create ("browser" or "worker").
    let defaultGradingMode: String
    let allowsBrowserGrading: Bool
    let requiresActivity: Bool
    let pushesGradesToLMS: Bool
    let allowsSlipDays: Bool
    /// The rules as sentences, the same words the web pages show.
    let rules: [String]

    init(_ type: AssignmentType) {
        name = type.rawValue
        displayName = type.displayName
        defaultGradingMode = type.defaultGradingMode.rawValue
        allowsBrowserGrading = type.allowsBrowserGrading
        requiresActivity = type.requiresActivity
        pushesGradesToLMS = type.pushesGradesToLMS
        allowsSlipDays = type.allowsSlipDays
        rules = AssignmentTypeRules.rules(for: type)
    }

    /// Every type, in declaration order.
    static let all: [MCPAssignmentTypeCapability] = AssignmentType.allCases.map(Self.init)
}
