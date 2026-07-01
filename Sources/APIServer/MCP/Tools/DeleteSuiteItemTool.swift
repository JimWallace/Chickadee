// APIServer/MCP/Tools/DeleteSuiteItemTool.swift
//
// Write tool: remove one item from an assignment's test suite — a hand-written
// script, a pattern family (and all its generated cases), or a notebook check.
// content:write, course-scoped.  Complements author_script / create_pattern_family
// (which add or replace): until this tool existed there was no MCP way to delete
// a suite item — only the browser editor could, via its full-payload PUT /suite.
//
// Read-modify-write through the same buildSuitePayload / applySuiteEdit path the
// editor uses: loads the authored suite, drops the matching row, and re-saves —
// which rebuilds the manifest (the dropped item is no longer graded), prunes a
// removed family's generated scripts from the zip, and re-runs validation
// (rejecting, e.g., a dangling dependsOn left by the removal).
//
// Targets exactly one item, identified by one of: `script` (hand-written
// filename), `familyID` (pattern family id), or `check` (notebook-check id).
// A generated family case is NOT a `script` row — to remove those, delete the
// family.

import Core
import Fluent
import Foundation
import Vapor

struct DeleteSuiteItemTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// Hand-written script filename to remove (kind == "script").
        let script: String?
        /// Pattern family id to remove (kind == "family"); also removes the
        /// family's generated case scripts.
        let familyID: String?
        /// Notebook-check id to remove (kind == "check").
        let check: String?
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        /// "script", "family", or "check".
        let kind: String
        /// The identifier of the removed item (filename / family id / check id).
        let removed: String
        let remainingItemCount: Int
        let validationStatus: String?
        /// true when this edit closed a previously-open (or preview) assignment.
        let assignmentClosed: Bool
    }

    static let name = "delete_suite_item"
    static let description =
        "Remove one item from an assignment's test suite, by public ID. Specify exactly one of: "
        + "`script` (a hand-written script filename), `familyID` (a pattern family id — also removes "
        + "its generated cases), or `check` (a notebook-check id). A generated family case is not a "
        + "`script`; to remove those delete the family. Saving rebuilds the manifest (the item is no "
        + "longer graded), closes the assignment if it was open (reported as `assignmentClosed`; re-open "
        + "with update_assignment once validation passes), and re-runs validation, which rejects the "
        + "removal if it would leave a dangling dependsOn. Ids and filenames come from get_suite."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "script": .object([
                "type": .string("string"),
                "description": .string("Hand-written script filename to remove."),
            ]),
            "familyID": .object([
                "type": .string("string"),
                "description": .string("Pattern family id to remove (with its generated cases)."),
            ]),
            "check": .object([
                "type": .string("string"),
                "description": .string("Notebook-check id to remove."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object(["type": .string("string")]),
            "kind": .object(["type": .string("string")]),
            "removed": .object(["type": .string("string")]),
            "remainingItemCount": .object(["type": .string("integer")]),
            "validationStatus": .object(["type": .string("string")]),
            "assignmentClosed": .object(["type": .string("boolean")]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("kind"), .string("removed"),
            .string("remainingItemCount"), .string("assignmentClosed"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: true, idempotentHint: false)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let target = try Self.resolveTarget(input)

        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, tool: Self.name, atLeast: .ta)

        var payload = buildSuitePayload(fromManifest: setup.manifest, zipPath: setup.zipPath)
        guard let idx = payload.items.firstIndex(where: { Self.matches($0, target) }) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "No \(target.kind) \"\(target.id)\" found in the suite (see get_suite).")
        }
        payload.items.remove(at: idx)

        try await applySuiteEditMapped(setup: setup, body: payload, tool: Self.name, on: context.db)
        // Close, re-grade, and re-validate (matching the web Save button).
        let closed = try await finalizeContentEdit(
            assignment: assignment, setup: setup, context: context, retest: true)

        return Output(
            assignmentPublicID: assignment.publicID,
            kind: target.kind,
            removed: target.id,
            remainingItemCount: payload.items.count,
            validationStatus: assignment.validationStatus,
            assignmentClosed: closed)
    }

    private struct Target { let kind: String; let id: String }

    /// Validates that exactly one of script / familyID / check is set and
    /// returns the (kind, id) to remove.
    private static func resolveTarget(_ input: Input) throws -> Target {
        var targets: [Target] = []
        if let s = input.script, !s.isEmpty { targets.append(Target(kind: "script", id: s)) }
        if let f = input.familyID, !f.isEmpty { targets.append(Target(kind: "family", id: f)) }
        if let c = input.check, !c.isEmpty { targets.append(Target(kind: "check", id: c)) }
        guard targets.count == 1 else {
            throw MCPToolError.invalidArguments(
                tool: name, detail: "Specify exactly one of: script, familyID, check.")
        }
        return targets[0]
    }

    private static func matches(_ item: SuiteItemDTO, _ target: Target) -> Bool {
        switch target.kind {
        case "script": return item.kind == "script" && item.script?.script == target.id
        case "family": return item.kind == "family" && item.family?.id == target.id
        case "check": return item.kind == "check" && item.check?.id == target.id
        default: return false
        }
    }
}
