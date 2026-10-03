// APIServer/MCP/Admin/Tools/GetHealthAlertsTool.swift
//
// Read tool: live evaluation of the server-health alert rules (database
// reachability, runner offline, queue backed up, error-rate spike) with the
// configured thresholds — whether each is currently firing, a human summary,
// and the supporting numbers (counts, ages, rates).  Evaluated on demand, so it
// reflects current state regardless of whether the alerting webhook is enabled.
// PII-free: details carry counts/thresholds, never student identifiers.

import Core
import Vapor

struct GetHealthAlertsTool: DiagnosticTool {
    struct Input: Decodable, Sendable {}

    struct RuleStatus: Encodable, Sendable {
        let rule: String
        let label: String
        let severity: String
        let firing: Bool
        let summary: String
        let details: [String: String]
    }

    struct Output: Encodable, Sendable {
        /// True when any rule is currently firing.
        let anyFiring: Bool
        let rules: [RuleStatus]
    }

    static let name = "get_health_alerts"
    static let description =
        "Live server-health rule evaluation: for each rule (\(ruleList)) "
        + "reports whether it is currently firing, a human summary, and the supporting numbers "
        + "(pending count, oldest-pending age, the IDs of runners that stopped polling, "
        + "system-failure rate, post-idle exec_hang count, configured thresholds). Evaluated on demand, independent of whether alert delivery is enabled. "
        + "Read-only; counts and thresholds only — no student identifiers."
    static let inputSchema: JSONValue = MCPSchema.noArgumentsInput

    /// Every rule's label as it reads mid-sentence, from `HealthRule.allCases`
    /// (#1935). The list was typed by hand and named six of the nine rules,
    /// while `execute` below reports all of them. A first word with a capital
    /// inside it is a name ("BrightSpace") and keeps its case.
    static var ruleList: String {
        HealthRule.allCases.map { rule in
            let label = rule.humanReadable
            guard let firstWord = label.split(separator: " ").first,
                firstWord.dropFirst().allSatisfy({ !$0.isUppercase })
            else { return label }
            return label.prefix(1).lowercased() + label.dropFirst()
        }
        .joined(separator: ", ")
    }

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        try await context.requireAdminSubject(tool: Self.name)
        let app = context.request.application
        let evaluations = await evaluateHealthRules(
            on: app, configuration: app.serverHealthAlertConfiguration)
        let rules = HealthRule.allCases.map { rule -> RuleStatus in
            let evaluation = evaluations[rule] ?? .ok
            return RuleStatus(
                rule: rule.rawValue,
                label: rule.humanReadable,
                severity: rule.severity,
                firing: evaluation.isFiring,
                summary: evaluation.summary,
                details: evaluation.details)
        }
        return Output(anyFiring: rules.contains { $0.firing }, rules: rules)
    }
}
