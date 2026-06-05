// APIServer/MCP/Tools/MoveSuiteItemTool.swift
//
// Write tool: move one test-suite item (a hand-written script, a pattern
// family, or a notebook check) into a section — or ungroup it — by assignment
// public ID.  content:write, course-scoped.
//
// `update_suite` can already set a *script's* sectionID, but it edits items in
// place without reordering, so it can only retag an item that is already
// adjacent to its target section's block; and it cannot move a pattern family
// or a notebook check at all.  This tool fills both gaps: it works on any item
// kind and it reorders the suite so the target section's items stay a
// contiguous block (the invariant `applyPatternFamilies` enforces), inserting
// the moved item next to that block (or into the trailing Ungrouped block when
// sectionID is empty).
//
// Like the other suite-editing write tools it goes through the validated
// `applySuiteEdit` reconcile path, then re-kicks validation and closes a
// currently-open assignment (re-open with update_assignment once validation
// passes).  Section names themselves are managed by create_suite_section /
// rename_suite_section / delete_suite_section.

import Core
import Fluent
import Foundation
import Vapor

struct MoveSuiteItemTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// Identify the item to move with exactly one of these.
        let script: String?
        let familyID: String?
        let check: String?
        /// Target section id (from get_suite / create_suite_section). Empty string or
        /// omitted ungroups the item (moves it to the trailing Ungrouped block).
        let sectionID: String?
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        /// "script", "family", or "check".
        let kind: String
        /// The moved item's identifier (filename / family id / check id).
        let item: String
        /// The section the item now lives in; "" when ungrouped.
        let sectionID: String
        /// The assignment's validation status after the move re-kicks validation.
        let validationStatus: String?
        /// true when this edit closed a previously-open assignment.
        let assignmentClosed: Bool
    }

    static let name = "move_suite_item"
    static let description =
        "Move one test-suite item into a section, or ungroup it, by assignment public ID. Identify the "
        + "item with exactly one of: script (a hand-written script filename), familyID (a pattern "
        + "family id), or check (a notebook-check id) — all from get_suite. sectionID is the target "
        + "section's id (from get_suite or create_suite_section); pass \"\" (or omit) to ungroup. The server "
        + "reorders the suite so each section stays a contiguous block. Saving re-runs validation and "
        + "closes the assignment if it was open (re-open with update_assignment once validation "
        + "passes). Use this for families and checks (which update_suite cannot move) and whenever a "
        + "move would otherwise break section contiguity."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "script": .object([
                "type": .string("string"),
                "description": .string("Hand-written script filename to move (one identifier only)."),
            ]),
            "familyID": .object([
                "type": .string("string"),
                "description": .string("Pattern family id to move (one identifier only)."),
            ]),
            "check": .object([
                "type": .string("string"),
                "description": .string("Notebook-check id to move (one identifier only)."),
            ]),
            "sectionID": .object([
                "type": .string("string"),
                "description": .string(
                    "Target section id, or \"\" to ungroup. Must reference an existing section."),
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
            "item": .object(["type": .string("string")]),
            "sectionID": .object(["type": .string("string")]),
            "validationStatus": .object(["type": .string("string")]),
            "assignmentClosed": .object(["type": .string("boolean")]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("kind"), .string("item"),
            .string("sectionID"), .string("assignmentClosed"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let resolved = try await resolveSetupForSectionEdit(
            assignmentPublicID: input.assignmentPublicID, tool: Self.name, context: context)

        var payload = buildSuitePayload(fromManifest: resolved.setup.manifest, zipPath: resolved.setup.zipPath)

        // Resolve which single item is targeted.
        let target = try Self.resolveTarget(input: input, items: payload.items)

        // Resolve + validate the destination section (nil == ungrouped).
        let destination = input.sectionID.flatMap { $0.isEmpty ? nil : $0 }
        if let destination {
            guard payload.sections.contains(where: { $0.id == destination }) else {
                throw MCPToolError.invalidArguments(
                    tool: Self.name,
                    detail: "No section with id \"\(destination)\". Create it with create_suite_section first.")
            }
        }

        // No-op when the item is already in the destination section: nothing to
        // reorder, no validation churn, no close.
        if payload.items[target.index].sectionID == destination {
            return Output(
                assignmentPublicID: resolved.assignment.publicID,
                kind: target.kind, item: target.id,
                sectionID: destination ?? "",
                validationStatus: resolved.assignment.validationStatus,
                assignmentClosed: false)
        }

        // Surgical move: pull the item out, retag it, and reinsert it adjacent
        // to the destination's existing contiguous block (or append it as the
        // start of a new block / the trailing Ungrouped block when empty). This
        // keeps every section's items contiguous, which applyPatternFamilies
        // requires, while leaving all other items' relative order untouched.
        var moved = payload.items.remove(at: target.index)
        moved.sectionID = destination
        if let anchor = payload.items.lastIndex(where: { $0.sectionID == destination }) {
            payload.items.insert(moved, at: payload.items.index(after: anchor))
        } else {
            payload.items.append(moved)
        }

        do {
            try await applySuiteEdit(setup: resolved.setup, body: payload, on: context.db)
        } catch let error as WebAssignmentError {
            throw MCPToolError.from(error, tool: Self.name)
        } catch let error as any AbortError {
            throw MCPToolError.from(error, tool: Self.name)
        }

        let closed = try await closeOpenAssignmentForContentEdit(resolved.assignment, on: context.db)
        await scheduleValidationAfterSuiteEdit(req: context.request, assignment: resolved.assignment)

        return Output(
            assignmentPublicID: resolved.assignment.publicID,
            kind: target.kind, item: target.id,
            sectionID: destination ?? "",
            validationStatus: resolved.assignment.validationStatus,
            assignmentClosed: closed)
    }

    // MARK: - Target resolution

    private struct Target {
        let index: Int
        let kind: String
        let id: String
    }

    /// Resolves exactly one of script / familyID / check to its position in the
    /// suite item list.  Throws when zero or more than one identifier is given,
    /// or when the named item isn't in the suite.
    private static func resolveTarget(input: Input, items: [SuiteItemDTO]) throws -> Target {
        let script = input.script.flatMap { $0.isEmpty ? nil : $0 }
        let familyID = input.familyID.flatMap { $0.isEmpty ? nil : $0 }
        let check = input.check.flatMap { $0.isEmpty ? nil : $0 }

        let provided = [script, familyID, check].compactMap { $0 }
        guard provided.count == 1 else {
            throw MCPToolError.invalidArguments(
                tool: name,
                detail: "Provide exactly one of script, familyID, or check to identify the item to move.")
        }

        if let script {
            guard let i = items.firstIndex(where: { $0.kind == "script" && $0.script?.script == script })
            else {
                throw MCPToolError.invalidArguments(
                    tool: name, detail: "No hand-written script named \"\(script)\" in the suite.")
            }
            return Target(index: i, kind: "script", id: script)
        }
        if let familyID {
            guard let i = items.firstIndex(where: { $0.kind == "family" && $0.family?.id == familyID })
            else {
                throw MCPToolError.invalidArguments(
                    tool: name, detail: "No pattern family with id \"\(familyID)\" in the suite.")
            }
            return Target(index: i, kind: "family", id: familyID)
        }
        // check
        let cid = check ?? ""
        guard let i = items.firstIndex(where: { $0.kind == "check" && $0.check?.id == cid }) else {
            throw MCPToolError.invalidArguments(
                tool: name, detail: "No notebook check with id \"\(cid)\" in the suite.")
        }
        return Target(index: i, kind: "check", id: cid)
    }
}
