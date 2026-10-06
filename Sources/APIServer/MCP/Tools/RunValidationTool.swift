// APIServer/MCP/Tools/RunValidationTool.swift
//
// Write tool: queue a fresh validation run of an assignment's reference
// solution against its current suite, optionally on one named runner, and wait
// for the result. content:write, course-scoped, TA or above.
//
// It changes no content. Validation otherwise runs only after a content edit,
// so checking a runner used to mean editing a suite to get a job queued, and
// any runner could then claim that job. Here the run asks for `runnerID`: for
// `RunnerTargetGate.fallbackSeconds` only that runner may claim it, and after
// that any compatible runner may, so an offline target delays the run and never
// strands it. The output names the runner that graded the run, so a fallback
// is visible.
//
// It does not close an open assignment or regrade student work, because the
// suite and the solution are unchanged.

import Core
import Fluent
import Foundation

struct RunValidationTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// The runner to ask for, as `get_validation_result` and the admin
        /// runner list name it. Omit for any runner.
        let runnerID: String?
        /// Maximum seconds to wait for a terminal result (1...120, default 30).
        let timeoutSeconds: Int?
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let validationStatus: String
        let timedOut: Bool
        /// The runner the run asked for; nil when it asked for none.
        let targetRunnerID: String?
        /// The runner that claimed the run; nil while it is still queued.
        let runnerID: String?
    }

    /// How recently a runner must have polled to be named as a target. Matches
    /// the window the unclaimable-jobs rule calls online.
    static let onlineRunnerSeconds: TimeInterval = 120

    static let name = "run_validation"
    static let description =
        "Queue a fresh validation run of an assignment's reference solution against its current suite, "
        + "by assignment public ID, and wait (up to timeoutSeconds, default 30) for the result. Use it to "
        + "re-check a suite without editing it, or to see how one runner grades it: with runnerID, only "
        + "that runner may claim the run for the first \(Int(RunnerTargetGate.fallbackSeconds / 60)) "
        + "minutes, and after that any compatible runner may. The runner must be online (it polled in "
        + "the last \(Int(onlineRunnerSeconds)) seconds). Returns validationStatus "
        + "(passed/failed/no-runner/pending), timedOut, and runnerID, the runner that claimed the run. "
        + "Changes no content, so it neither closes an open assignment nor regrades student work. Read "
        + "the per-test outcomes with get_validation_result."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "runnerID": .object([
                "type": .string("string"),
                "description": .string(
                    "The runner to ask for, e.g. \"Starling\". Omit to let any runner claim the run."),
            ]),
            "timeoutSeconds": .object([
                "type": .string("integer"),
                "description": .string("Max seconds to wait for a terminal result (1-120, default 30)."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "validationStatus": MCPSchema.string,
            "timedOut": MCPSchema.boolean,
            "targetRunnerID": .object(["type": .array([.string("string"), .string("null")])]),
            "runnerID": .object(["type": .array([.string("string"), .string("null")])]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("validationStatus"), .string("timedOut"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: false)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let (assignment, _) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, atLeast: .ta)
        let target = try await Self.resolveTarget(input.runnerID, context: context)
        let subject = try await context.requireEligibleSubject()
        let subjectID = try subject.requireID()

        do {
            _ = try await requeueValidationRun(
                req: context.request, assignment: assignment, submitterUserID: subjectID,
                targetRunnerID: target)
        } catch ValidationRunError.noSolution {
            throw MCPToolError.invalidArguments(
                detail: "Assignment \(assignment.publicID) has no reference solution to validate. "
                    + "Add one with update_solution.")
        } catch {
            throw MCPToolError.executionFailed(detail: "Could not queue the validation run: \(error)")
        }

        let timeout = ValidateAssignmentTool.clampTimeout(input.timeoutSeconds)
        let outcome = try await watchValidation(
            on: context.db,
            assignmentPublicID: assignment.publicID,
            pollInterval: .milliseconds(500),
            deadline: ContinuousClock().now.advanced(by: .seconds(timeout)),
            emit: { _, _ in })

        let claimedBy = try await MCPStudentDataBoundary.validationSubmission(
            for: assignment, on: context.db)?.workerID
        return Output(
            assignmentPublicID: outcome.assignmentPublicID,
            validationStatus: outcome.validationStatus,
            timedOut: outcome.timedOut,
            targetRunnerID: target,
            runnerID: claimedBy)
    }

    /// The trimmed target, or nil for none. A named runner must be online, so
    /// a misspelled name fails here instead of waiting out the fallback.
    static func resolveTarget(_ runnerID: String?, context: ToolContext) async throws -> String? {
        guard let name = runnerID?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        let online = await context.request.application.workerActivityStore
            .activeRunners(withinSeconds: onlineRunnerSeconds)
            .map(\.workerID)
        guard online.contains(name) else {
            let list = online.isEmpty ? "none" : online.joined(separator: ", ")
            throw MCPToolError.invalidArguments(
                detail: "Runner \"\(name)\" has not polled in the last \(Int(onlineRunnerSeconds)) seconds. "
                    + "Online runners: \(list).")
        }
        return name
    }
}
