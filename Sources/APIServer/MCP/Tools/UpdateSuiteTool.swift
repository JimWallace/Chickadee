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
//
// `anchor` pins a script to a notebook cell (docs/notebook-guide.md, "Pin to a
// cell") through `SuiteAnchorPinning`, the rule the web pin route uses. Grading
// never reads a pin, so a call whose every edit sets only `anchor` neither
// closes, re-grades nor re-validates, as the web route does not.

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
        /// Student-facing failure detail (`FailureDetail` raw value). Sets the
        /// level; "" or "full" reverts to full; absent leaves it unchanged.
        let failureDetail: String?
        /// The notebook cell name the script is pinned to: a name sets the
        /// pin, "" clears it, absent leaves it unchanged.
        let anchor: String?

        // Explicit init so `timeLimitSeconds` can default to nil — keeps the
        // older positional/labelled call sites (which predate the field)
        // compiling without threading nil through each one.
        init(
            script: String, tier: String? = nil, points: Int? = nil,
            displayName: String? = nil, dependsOn: [String]? = nil,
            sectionID: String? = nil, timeLimitSeconds: Int? = nil,
            failureDetail: String? = nil, anchor: String? = nil
        ) {
            self.script = script
            self.tier = tier
            self.points = points
            self.displayName = displayName
            self.dependsOn = dependsOn
            self.sectionID = sectionID
            self.timeLimitSeconds = timeLimitSeconds
            self.failureDetail = failureDetail
            self.anchor = anchor
        }

        /// True when the edit sets the pin and nothing that grading reads.
        /// A new field must be added here, or an edit of it alone would skip
        /// the close and the re-validation.
        var changesOnlyAnchor: Bool {
            anchor != nil && tier == nil && points == nil && displayName == nil && dependsOn == nil
                && sectionID == nil && timeLimitSeconds == nil && failureDetail == nil
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
        + "script provide any of: tier (\(MCPTierProse.slashAlternatives)), points, displayName, "
        + "dependsOn (prerequisite script names), sectionID (\"\" to ungroup), and timeLimitSeconds "
        + "(a per-test execution time limit override in seconds, \(mcpTimeLimitRangeText); 0 clears the override so the "
        + "script reverts to the assignment default set by set_time_limit), and failureDetail "
        + "(\(MCPFailureDetailProse.slashAlternatives) — how much of a failing run the student sees; "
        + "\"full\" reverts to the default), and anchor (the name of the notebook cell the test "
        + "belongs to: a function or variable the cell defines, or a \"## \" section heading; "
        + "\"\" clears the pin and the test is anchored automatically again). Does NOT change "
        + "script content or pattern families; a generated test is anchored by its family or check "
        + "and cannot be pinned. Saving re-runs the assignment's validation and closes "
        + "the assignment if it was open (re-open with update_assignment once validation passes). "
        + "Grading never reads a pin, so a call whose every edit sets only anchor saves the pin and "
        + "nothing else: no validation, no regrade, no close. get_suite reports each script's pin."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
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
                        "tier": MCPSchema.tierEnum(),
                        "points": MCPSchema.integer,
                        "displayName": MCPSchema.string,
                        "dependsOn": .object([
                            "type": .string("array"), "items": MCPSchema.string,
                        ]),
                        "sectionID": .object([
                            "type": .string("string"),
                            "description": .string("Section id, or \"\" to ungroup."),
                        ]),
                        "timeLimitSeconds": MCPSchema.timeLimit(
                            "Per-test time-limit override in seconds (\(mcpTimeLimitRangeText)); "
                                + "0 clears the override (revert to the assignment default)."),
                        "failureDetail": MCPFailureDetailProse.schema(MCPFailureDetailProse.fieldDescription),
                        "anchor": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Pin the test to the notebook cell that defines this name (or to a "
                                    + "\"## \" section heading); \"\" clears the pin. Display only: "
                                    + "the student guide and the workbench place the test by it."),
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
            "assignmentPublicID": MCPSchema.string,
            "updatedScripts": .object([
                "type": .string("array"), "items": MCPSchema.string,
            ]),
            "validationStatus": MCPSchema.string,
            "assignmentClosed": MCPSchema.boolean,
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
            throw MCPToolError.invalidArguments(detail: "Provide at least one edit.")
        }
        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, atLeast: .ta)
        let pins = input.edits.compactMap { edit in
            edit.anchor.map { SuiteAnchorPinning.Pin(script: edit.script, anchor: $0) }
        }

        // Refuse a bad pin before anything is written: the metadata save below
        // and the pin write are two manifest edits, and a pin refused after the
        // first would leave a changed suite that nothing closed or re-validated.
        if let manifest = setup.decodedManifest(), let refusal = SuiteAnchorPinning.refusal(of: pins, in: manifest) {
            throw MCPToolError.invalidArguments(detail: refusal.message)
        }

        // Pins only: grading never reads a pin, so nothing closes, re-grades
        // or re-validates, as with the web pin route.
        if input.edits.allSatisfy(\.changesOnlyAnchor) {
            try await Self.applyPins(pins, setup: setup, context: context)
            return Output(
                assignmentPublicID: assignment.publicID,
                updatedScripts: input.edits.map(\.script),
                validationStatus: assignment.validationStatus,
                assignmentClosed: false)
        }

        // Load the full authored suite with script bodies preserved from the zip.
        var payload = await buildSuitePayload(fromManifest: setup.manifest, zipPath: setup.zipPath)
        var updated: [String] = []
        for edit in input.edits {
            let tier = try parseOptionalTier(edit.tier)
            guard
                let idx = payload.items.firstIndex(where: {
                    $0.kind == "script" && $0.script?.script == edit.script
                })
            else {
                throw MCPToolError.invalidArguments(detail: "No script named \"\(edit.script)\" in the suite.")
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
            let storedLimit = payload.items[idx].script?.timeLimitSeconds
            payload.items[idx].script?.timeLimitSeconds = try parseTimeLimitOverride(
                edit.timeLimitSeconds, field: "timeLimitSeconds"
            ).applied(to: storedLimit)
            if let detailUpdate = try MCPFailureDetailProse.parse(
                edit.failureDetail, field: "failureDetail")
            {
                payload.items[idx].script?.failureDetail = detailUpdate?.rawValue
            }
            updated.append(edit.script)
        }

        try await applySuiteEditMapped(setup: setup, body: payload, on: context.db)
        try await Self.applyPins(pins, setup: setup, context: context)
        // Close, re-grade, and re-validate (matching the web Save button).
        let finalized = try await finalizeContentEdit(
            assignment: assignment, setup: setup, context: context, retest: true)

        return Output(
            assignmentPublicID: assignment.publicID,
            updatedScripts: updated,
            validationStatus: assignment.validationStatus,
            assignmentClosed: finalized.assignmentClosed)
    }

    /// Writes the pins, mapping a refused pin to an arguments error the agent
    /// can fix.
    private static func applyPins(
        _ pins: [SuiteAnchorPinning.Pin], setup: APITestSetup, context: ToolContext
    ) async throws {
        do {
            try await SuiteAnchorPinning.apply(pins, setup: setup, on: context.db)
        } catch let error as SuiteAnchorPinning.PinError {
            throw MCPToolError.invalidArguments(detail: error.message)
        }
    }
}
