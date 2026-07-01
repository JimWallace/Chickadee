// APIServer/MCP/Tools/SuiteSectionTools.swift
//
// Write tools for test-suite *sections* — the named display groups introduced
// in v0.4.96.  content:write, course-scoped.
//
// Sections are a pure display concern: they group tests under a heading in the
// student results view and the suite editor, but they do not affect the
// dependency graph, run order, or what a test checks.  So these three tools
// mutate ONLY the manifest's `sections` list (and, on delete, clear the
// `sectionID` of any items that referenced the removed section) via the shared
// `mutateManifest` helper — exactly like the web
// `POST /instructor/:id/suite-sections{,/:sid/rename,/:sid/delete}` handlers.
// They deliberately bypass `applyPatternFamilies`, the zip rebuild, and the
// validation/close machinery: a section rename can never change a grade, so
// none of that pipeline needs to run.
//
// Placing tests into a section (and keeping each section's items contiguous) is
// a separate concern handled by `move_suite_item` (which goes through the
// validated suite-reconcile path because it reorders the suite).

import Core
import Fluent
import Foundation

// MARK: - create_suite_section

struct CreateSuiteSectionTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        let name: String
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let sectionID: String
        let name: String
    }

    static let name = "create_suite_section"
    static let description =
        "Create a new, empty test-suite section (a named display group) on an assignment, by its "
        + "public ID. Returns the new section's id; put tests into it with move_suite_item (or pass "
        + "the id as sectionID to author_script / update_suite). Sections are display-only — they "
        + "group tests under a heading in the student results view and the suite editor and do not "
        + "affect grading, run order, or dependencies — so this does NOT re-run validation or close "
        + "the assignment. Section display order follows creation order; create them in the order you "
        + "want students to see."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "name": .object([
                "type": .string("string"),
                "description": .string("Display name for the new section (non-empty)."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("name")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object(["type": .string("string")]),
            "sectionID": .object(["type": .string("string")]),
            "name": .object(["type": .string("string")]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("sectionID"), .string("name"),
        ]),
    ])
    // Appends a fresh section each call, so repeated calls are NOT idempotent.
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: false)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw MCPToolError.invalidArguments(tool: Self.name, detail: "Section name must not be empty.")
        }
        let resolved = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, tool: Self.name, atLeast: .ta)
        let newID = UUID().uuidString
        do {
            try await mutateManifest(setup: resolved.setup, on: context.db) { dict in
                var sections = (dict["sections"] as? [[String: Any]]) ?? []
                sections.append(["id": newID, "name": name])
                dict["sections"] = sections
            }
        } catch let error as WebAssignmentError {
            throw MCPToolError.from(error, tool: Self.name)
        }
        return Output(assignmentPublicID: resolved.assignment.publicID, sectionID: newID, name: name)
    }
}

// MARK: - rename_suite_section

struct RenameSuiteSectionTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        let sectionID: String
        let name: String
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let sectionID: String
        let name: String
    }

    static let name = "rename_suite_section"
    static let description =
        "Rename an existing test-suite section on an assignment, by assignment public ID + section id "
        + "(both from get_suite). Section names are display-only, so this does NOT re-run validation "
        + "or close the assignment."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "sectionID": .object([
                "type": .string("string"),
                "description": .string("The section's id (from get_suite)."),
            ]),
            "name": .object([
                "type": .string("string"),
                "description": .string("New display name (non-empty)."),
            ]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("sectionID"), .string("name"),
        ]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object(["type": .string("string")]),
            "sectionID": .object(["type": .string("string")]),
            "name": .object(["type": .string("string")]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("sectionID"), .string("name"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw MCPToolError.invalidArguments(tool: Self.name, detail: "Section name must not be empty.")
        }
        guard !input.sectionID.isEmpty else {
            throw MCPToolError.invalidArguments(tool: Self.name, detail: "sectionID must not be empty.")
        }
        let resolved = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, tool: Self.name, atLeast: .ta)
        do {
            try await mutateManifest(setup: resolved.setup, on: context.db) { dict in
                guard var sections = dict["sections"] as? [[String: Any]],
                    let idx = sections.firstIndex(where: { ($0["id"] as? String) == input.sectionID })
                else {
                    throw MCPToolError.invalidArguments(
                        tool: Self.name, detail: "No section with id \"\(input.sectionID)\".")
                }
                sections[idx]["name"] = name
                dict["sections"] = sections
            }
        } catch let error as WebAssignmentError {
            throw MCPToolError.from(error, tool: Self.name)
        }
        return Output(assignmentPublicID: resolved.assignment.publicID, sectionID: input.sectionID, name: name)
    }
}

// MARK: - delete_suite_section

struct DeleteSuiteSectionTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        let sectionID: String
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let sectionID: String
        /// false when no section with that id existed (idempotent no-op).
        let removed: Bool
        /// How many test items were ungrouped (their `sectionID` cleared) as a
        /// result; they flow into the trailing Ungrouped block.
        let ungroupedItemCount: Int
    }

    static let name = "delete_suite_section"
    static let description =
        "Delete a test-suite section on an assignment, by assignment public ID + section id. Any tests "
        + "in the section are NOT deleted — they are ungrouped (moved to the trailing Ungrouped block). "
        + "Deleting only removes the named display group, so this does NOT re-run validation or close "
        + "the assignment. Idempotent: deleting an id that no longer exists reports removed=false."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "sectionID": .object([
                "type": .string("string"),
                "description": .string("The section's id (from get_suite)."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("sectionID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object(["type": .string("string")]),
            "sectionID": .object(["type": .string("string")]),
            "removed": .object(["type": .string("boolean")]),
            "ungroupedItemCount": .object(["type": .string("integer")]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("sectionID"), .string("removed"),
            .string("ungroupedItemCount"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: true, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        guard !input.sectionID.isEmpty else {
            throw MCPToolError.invalidArguments(tool: Self.name, detail: "sectionID must not be empty.")
        }
        let resolved = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, tool: Self.name, atLeast: .ta)
        // Captured inside the mutation closure so the response reflects what
        // actually changed.
        var removed = false
        var ungrouped = 0
        do {
            try await mutateManifest(setup: resolved.setup, on: context.db) { dict in
                if var sections = dict["sections"] as? [[String: Any]] {
                    let before = sections.count
                    sections.removeAll { ($0["id"] as? String) == input.sectionID }
                    removed = sections.count != before
                    dict["sections"] = sections
                }
                // Clear matching entries' sectionID so the affected items flow
                // into the trailing Ungrouped block (mirrors the web handler).
                if var testSuites = dict["testSuites"] as? [[String: Any]] {
                    for i in testSuites.indices
                    where (testSuites[i]["sectionID"] as? String) == input.sectionID {
                        testSuites[i].removeValue(forKey: "sectionID")
                        ungrouped += 1
                    }
                    dict["testSuites"] = testSuites
                }
            }
        } catch let error as WebAssignmentError {
            throw MCPToolError.from(error, tool: Self.name)
        }
        return Output(
            assignmentPublicID: resolved.assignment.publicID,
            sectionID: input.sectionID,
            removed: removed,
            ungroupedItemCount: ungrouped)
    }
}
