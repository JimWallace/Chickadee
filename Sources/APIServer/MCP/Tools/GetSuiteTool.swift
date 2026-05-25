// APIServer/MCP/Tools/GetSuiteTool.swift
//
// Read tool: returns an assignment's test-suite structure by public ID — the
// ordered items (hand-written scripts, generated pattern families, notebook
// checks) with tier/points/dependencies/section, plus the section list.
// content:read, course-scoped. Reuses the author-facing `buildSuitePayload`
// (without a zip path, so raw script bodies are NOT included — this is a
// structure view; editing the suite is a later phase).

import Core
import Fluent
import Foundation

struct GetSuiteTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
    }

    struct Output: Encodable, Sendable {
        struct Section: Encodable, Sendable {
            let id: String
            let name: String
        }
        struct Item: Encodable, Sendable {
            /// "script", "family", or "check".
            let kind: String
            /// Script filename, family name, or check name.
            let name: String
            /// "public", "release", "secret", or "student".
            let tier: String
            let points: Int
            let displayName: String?
            /// Prerequisite items; may contain "family:<id>" tokens (author form).
            let dependsOn: [String]
            /// Section this item belongs to, or nil if ungrouped.
            let sectionID: String?
            /// The pattern-family id, for `kind == "family"` items.
            let familyID: String?
        }
        let assignmentPublicID: String
        let sections: [Section]
        let items: [Item]
    }

    static let name = "get_suite"
    static let description =
        "Get an assignment's test-suite structure by public ID: the ordered test items "
        + "(hand-written scripts, generated pattern families, notebook checks) with their tier "
        + "(public/release/secret/student), points, display name, dependencies, and section, plus "
        + "the section list. Read-only — use this to inspect the suite before editing it."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ])
        ]),
        "required": .array([.string("assignmentPublicID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object(["type": .string("string")]),
            "sections": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string")]),
                        "name": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("id"), .string("name")]),
                ]),
            ]),
            "items": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "kind": .object(["type": .string("string")]),
                        "name": .object(["type": .string("string")]),
                        "tier": .object(["type": .string("string")]),
                        "points": .object(["type": .string("integer")]),
                        "displayName": .object(["type": .string("string")]),
                        "dependsOn": .object([
                            "type": .string("array"), "items": .object(["type": .string("string")]),
                        ]),
                        "sectionID": .object(["type": .string("string")]),
                        "familyID": .object(["type": .string("string")]),
                    ]),
                    "required": .array([
                        .string("kind"), .string("name"), .string("tier"), .string("points"),
                        .string("dependsOn"),
                    ]),
                ]),
            ]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("sections"), .string("items"),
        ]),
    ])
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        guard let assignment = try await assignmentByPublicID(input.assignmentPublicID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "No assignment found with public ID \"\(input.assignmentPublicID)\".")
        }
        try await context.authorizeCourseAccess(assignment.courseID, tool: Self.name)
        guard let setup = try await APITestSetup.find(assignment.testSetupID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "The assignment's test setup could not be found.")
        }

        // No zip path → metadata-only rows (raw script bodies omitted).
        let payload = buildSuitePayload(fromManifest: setup.manifest)
        let sections = payload.sections.map { Output.Section(id: $0.id, name: $0.name) }
        let items = payload.items.map { Self.item(from: $0) }
        return Output(assignmentPublicID: assignment.publicID, sections: sections, items: items)
    }

    private static func item(from dto: SuiteItemDTO) -> Output.Item {
        switch dto.kind {
        case "family":
            let family = dto.family
            return Output.Item(
                kind: "family",
                name: family?.name ?? "(family)",
                tier: (family?.defaults.tier ?? .pub).rawValue,
                points: family?.defaults.points ?? 0,
                displayName: nil,
                dependsOn: dto.dependsOn ?? family?.dependsOn ?? [],
                sectionID: dto.sectionID,
                familyID: family?.id)
        case "check":
            let check = dto.check
            return Output.Item(
                kind: "check",
                name: check?.name ?? check?.id ?? "(check)",
                tier: (check?.tier ?? .pub).rawValue,
                points: check?.points ?? 0,
                displayName: nil,
                dependsOn: dto.dependsOn ?? check?.dependsOn ?? [],
                sectionID: dto.sectionID,
                familyID: nil)
        default:
            let script = dto.script
            return Output.Item(
                kind: "script",
                name: script?.script ?? "(script)",
                tier: (script?.tier ?? .pub).rawValue,
                points: script?.points ?? 0,
                displayName: script?.displayName,
                dependsOn: script?.dependsOn ?? [],
                sectionID: dto.sectionID,
                familyID: nil)
        }
    }
}
