// APIServer/MCP/Admin/Tools/ListRunnersTool.swift
//
// Read tool: the runner fleet — one row per runner seen recently, with load,
// all-time jobs processed, and rolling average execution / queue-wait.  Wraps
// the same builder the admin dashboard's runner table uses (`makeWorkerRows`):
// operational runner state only — no user, submission, course, or assignment
// identifiers.  Pairs with get_runner_detail (one runner's capability profile +
// per-stage timing breakdown).

import Core
import Vapor

struct ListRunnersTool: DiagnosticTool {
    struct Input: Decodable, Sendable {}

    struct Output: Encodable, Sendable {
        let generatedAt: Date
        let activeRunnerCount: Int
        let runners: [AdminWorkerRow]
    }

    static let name = "list_runners"
    static let description =
        "The runner fleet: one row per runner seen in the last hour — runner id, hostname, version, "
        + "current load (assigned/max concurrent jobs), all-time jobs processed, and rolling average "
        + "execution + queue-wait time (last 50 jobs). Use it to see which runners are online and how "
        + "they're performing; pair with get_runner_detail for one runner's capability profile and "
        + "per-stage timing breakdown. Read-only; operational runner state only — no student, "
        + "submission, course, or assignment identifiers."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        try await context.requireAdminSubject(tool: Self.name)
        let runners = try await makeWorkerRows(req: context.request)
        return Output(generatedAt: Date(), activeRunnerCount: runners.count, runners: runners)
    }
}
