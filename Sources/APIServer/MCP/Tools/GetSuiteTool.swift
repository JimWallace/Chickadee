// APIServer/MCP/Tools/GetSuiteTool.swift
//
// Read tool: returns an assignment's full test-suite definition by public ID —
// the ordered items (hand-written scripts, generated pattern families, notebook
// checks) with tier/points/dependencies/section, plus the section list.
// content:read, course-scoped. Reuses the author-facing `buildSuitePayload`
// *with* the test setup's zip path, so the response carries the complete
// declarative state an instructor sees in the suite editor: raw script bodies
// (`content`), each pattern family's full spec including every case's
// args/expected (`family`), and notebook-check specs (`check`). This is the
// same authoring content `GET /instructor/:id/suite` returns to the browser.

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
            /// Section-scoped literal personalization values (name + JSON value).
            let variables: [FamilyVariable]
            /// Section-scoped per-student expressions (name + Python source).
            let expressions: [PersonalizationExpression]
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
            /// Raw hand-written script body, for `kind == "script"` items, read
            /// from the test setup zip. Nil for generated family/check rows
            /// (their source is derived from the spec) or if the file is absent.
            let content: String?
            /// Instructor hint for a hand-written script (`kind == "script"`).
            let hint: String?
            /// Full pattern-family spec — function, kind, paramNames, defaults,
            /// variables, and every case's args/expected — for `kind ==
            /// "family"` items. This is the source of truth the grader renders
            /// into Python, so it reveals the exact values each case checks.
            let family: PatternFamily?
            /// Full notebook-check spec, for `kind == "check"` items.
            let check: NotebookCheck?
        }
        let assignmentPublicID: String
        let sections: [Section]
        let items: [Item]
    }

    static let name = "get_suite"
    static let description =
        "Get an assignment's full test-suite definition by public ID: the ordered test items "
        + "(hand-written scripts, generated pattern families, notebook checks) with their tier "
        + "(public/release/secret/student), points, display name, dependencies, and section, plus "
        + "the section list. Each item also carries its source of truth: hand-written scripts "
        + "include their raw body (`content`) and `hint`; pattern families include the full spec "
        + "(`family`) with every case's args and expected value; notebook checks include their "
        + "spec (`check`). Read-only — use this to inspect exactly what each test checks (e.g. to "
        + "explain why a submission lost points) before editing the suite."
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
                        "variables": .object(["type": .string("array")]),
                        "expressions": .object(["type": .string("array")]),
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
                        "content": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Raw hand-written script body (kind == \"script\"); absent for "
                                    + "generated family/check rows."),
                        ]),
                        "hint": .object([
                            "type": .string("string"),
                            "description": .string("Instructor hint for a hand-written script."),
                        ]),
                        "family": .object([
                            "type": .string("object"),
                            "description": .string(
                                "Full pattern-family spec (kind == \"family\"): function, kind, "
                                    + "paramNames, defaults, variables, and every case's "
                                    + "args/expected — the exact values each case checks."),
                        ]),
                        "check": .object([
                            "type": .string("object"),
                            "description": .string("Full notebook-check spec (kind == \"check\")."),
                        ]),
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

        // Pass the zip path so raw hand-written script bodies are filled in
        // (generated family/check files are derived from their specs and need
        // no body). This gives the agent the same complete authoring view the
        // browser suite editor receives from `GET /instructor/:id/suite`.
        let payload = buildSuitePayload(fromManifest: setup.manifest, zipPath: setup.zipPath)
        // Section variables/expressions live on the manifest's section list,
        // not on the suite-payload DTO (which carries only id + name).
        let sectionInputs = Dictionary(
            uniqueKeysWithValues: (setup.decodedManifest()?.sections ?? []).map {
                ($0.id, (variables: $0.variables, expressions: $0.expressions))
            })
        let sections = payload.sections.map { section in
            Output.Section(
                id: section.id,
                name: section.name,
                variables: sectionInputs[section.id]?.variables ?? [],
                expressions: sectionInputs[section.id]?.expressions ?? [])
        }
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
                familyID: family?.id,
                content: nil,
                hint: nil,
                family: family,
                check: nil)
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
                familyID: nil,
                content: nil,
                hint: nil,
                family: nil,
                check: check)
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
                familyID: nil,
                content: script?.content,
                hint: script?.hint,
                family: nil,
                check: nil)
        }
    }
}
