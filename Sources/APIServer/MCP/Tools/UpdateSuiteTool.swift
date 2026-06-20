// APIServer/MCP/Tools/UpdateSuiteTool.swift
//
// Write tool: edit test-suite *script* metadata for an assignment — tier,
// points, display name, prerequisites (dependsOn), and section — by public ID.
// content:write, course-scoped.
//
// Targeted read-modify-write: loads the current authored suite (with script
// bodies preserved from the zip), applies the named per-script edits, and
// re-saves through the same `applySuiteEdit` path the web editor uses, then
// re-kicks validation. The agent never sends raw script content, so it can't
// corrupt test bodies. Pattern-family / notebook-check metadata and reordering
// are out of scope here (later phases).

import Core
import Fluent
import Foundation

struct UpdateSuiteTool: ContentTool {
    struct ScriptEdit: Decodable, Sendable {
        /// Target script filename (must already exist in the suite).
        let script: String
        let tier: String?
        let points: Int?
        let displayName: String?
        let dependsOn: [String]?
        /// Section id to move the script into; empty string ungroups it; absent
        /// leaves it unchanged.
        let sectionID: String?
        /// Per-test execution time limit override (seconds). A value in 1...600
        /// sets the override; 0 clears it (the script reverts to the assignment
        /// default); absent/null leaves it unchanged.
        let timeLimitSeconds: Int?

        // Explicit init so `timeLimitSeconds` can default to nil — keeps the
        // older positional/labelled call sites (which predate the field)
        // compiling without threading nil through each one.
        init(
            script: String, tier: String? = nil, points: Int? = nil,
            displayName: String? = nil, dependsOn: [String]? = nil,
            sectionID: String? = nil, timeLimitSeconds: Int? = nil
        ) {
            self.script = script
            self.tier = tier
            self.points = points
            self.displayName = displayName
            self.dependsOn = dependsOn
            self.sectionID = sectionID
            self.timeLimitSeconds = timeLimitSeconds
        }
    }

    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        let edits: [ScriptEdit]
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let updatedScripts: [String]
        /// The assignment's validation status after the edit re-kicks validation.
        let validationStatus: String?
        /// true when this edit closed a previously-open assignment (re-open with
        /// update_assignment once validation passes).
        let assignmentClosed: Bool
    }

    static let name = "update_suite"
    static let description =
        "Edit test-suite script metadata for an assignment, by its public ID. For each named "
        + "script provide any of: tier (public/release/secret/student), points, displayName, "
        + "dependsOn (prerequisite script names), sectionID (\"\" to ungroup), and timeLimitSeconds "
        + "(a per-test execution time limit override in seconds, 1–600; 0 clears the override so the "
        + "script reverts to the assignment default set by set_time_limit). Does NOT change "
        + "script content or pattern families. Saving re-runs the assignment's validation and closes "
        + "the assignment if it was open (re-open with update_assignment once validation passes)."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "edits": .object([
                "type": .string("array"),
                "description": .string("Per-script metadata edits; each targets an existing script by filename."),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "script": .object([
                            "type": .string("string"),
                            "description": .string("Target script filename (must already exist)."),
                        ]),
                        "tier": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("public"), .string("release"), .string("secret"), .string("student"),
                            ]),
                        ]),
                        "points": .object(["type": .string("integer")]),
                        "displayName": .object(["type": .string("string")]),
                        "dependsOn": .object([
                            "type": .string("array"), "items": .object(["type": .string("string")]),
                        ]),
                        "sectionID": .object([
                            "type": .string("string"),
                            "description": .string("Section id, or \"\" to ungroup."),
                        ]),
                        "timeLimitSeconds": .object([
                            "type": .string("integer"),
                            "description": .string(
                                "Per-test time-limit override in seconds "
                                    + "(\(mcpTimeLimitRange.lowerBound)–\(mcpTimeLimitRange.upperBound)); "
                                    + "0 clears the override (revert to the assignment default)."),
                        ]),
                    ]),
                    "required": .array([.string("script")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("edits")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object(["type": .string("string")]),
            "updatedScripts": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
            ]),
            "validationStatus": .object(["type": .string("string")]),
            "assignmentClosed": .object(["type": .string("boolean")]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("updatedScripts"), .string("assignmentClosed"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        guard !input.edits.isEmpty else {
            throw MCPToolError.invalidArguments(tool: Self.name, detail: "Provide at least one edit.")
        }
        let (assignment, setup) = try await context.authorizedAssignmentAndSetup(
            publicID: input.assignmentPublicID, tool: Self.name)

        // Load the full authored suite with script bodies preserved from the zip.
        var payload = buildSuitePayload(fromManifest: setup.manifest, zipPath: setup.zipPath)
        var updated: [String] = []
        for edit in input.edits {
            let tier = try parseOptionalTier(edit.tier, tool: Self.name)
            guard
                let idx = payload.items.firstIndex(where: {
                    $0.kind == "script" && $0.script?.script == edit.script
                })
            else {
                throw MCPToolError.invalidArguments(
                    tool: Self.name, detail: "No script named \"\(edit.script)\" in the suite.")
            }
            if let tier { payload.items[idx].script?.tier = tier }
            if let points = edit.points { payload.items[idx].script?.points = points }
            if let displayName = edit.displayName {
                payload.items[idx].script?.displayName = displayName.isEmpty ? nil : displayName
            }
            if let dependsOn = edit.dependsOn { payload.items[idx].script?.dependsOn = dependsOn }
            if let sectionID = edit.sectionID {
                payload.items[idx].sectionID = sectionID.isEmpty ? nil : sectionID
            }
            if let limit = edit.timeLimitSeconds {
                // 0 clears the override (revert to the assignment default); any
                // other value is validated to the accepted range.
                if limit == 0 {
                    payload.items[idx].script?.timeLimitSeconds = nil
                } else {
                    payload.items[idx].script?.timeLimitSeconds =
                        try validateTimeLimitSeconds(limit, tool: Self.name, field: "timeLimitSeconds")
                }
            }
            updated.append(edit.script)
        }

        try await applySuiteEditMapped(setup: setup, body: payload, tool: Self.name, on: context.db)
        // Close, re-grade, and re-validate (matching the web Save button).
        let closed = try await finalizeContentEdit(
            assignment: assignment, setup: setup, context: context, retest: true)

        return Output(
            assignmentPublicID: assignment.publicID,
            updatedScripts: updated,
            validationStatus: assignment.validationStatus,
            assignmentClosed: closed)
    }

}
