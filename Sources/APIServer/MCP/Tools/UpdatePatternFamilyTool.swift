// APIServer/MCP/Tools/UpdatePatternFamilyTool.swift
//
// Write tool: edit a pattern family's *metadata* for an assignment — its
// default tier/points, and which cases are enabled — by public ID + family id.
// content:write, course-scoped.
//
// Targeted read-modify-write through the same applySuiteEdit / applyPatternFamilies
// path the web editor uses: loads the current authored suite, reconstructs the
// family with the requested default + case-enabled changes (every other field —
// function, params, case args/expected/variables — is preserved verbatim), and
// re-saves, which regenerates the family's scripts and re-runs validation.
//
// The agent can re-weight/re-tier a family and turn cases on/off, but it does
// NOT author case args or expected values (the actual test logic) — that's a
// later, higher-risk slice, like notebook content.

import Core
import Fluent
import Foundation

struct UpdatePatternFamilyTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        let familyID: String
        let defaultTier: String?
        let defaultPoints: Int?
        let enableCases: [String]?
        let disableCases: [String]?
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let familyID: String
        let defaultTier: String
        let defaultPoints: Int
        let enabledCaseKeys: [String]
        let validationStatus: String?
    }

    static let name = "update_pattern_family"
    static let description =
        "Edit a pattern family's metadata for an assignment, by assignment public ID + family id. "
        + "Set the family's default tier (public/release/secret/student) and/or points, and "
        + "enable/disable individual cases by key (enableCases / disableCases). Does NOT change a "
        + "case's args or expected value (the test logic). Saving regenerates the family's scripts "
        + "and re-runs validation."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "familyID": .object([
                "type": .string("string"),
                "description": .string("The pattern family's id (from get_suite)."),
            ]),
            "defaultTier": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("public"), .string("release"), .string("secret"), .string("student"),
                ]),
            ]),
            "defaultPoints": .object(["type": .string("integer")]),
            "enableCases": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
                "description": .string("Case keys to enable."),
            ]),
            "disableCases": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
                "description": .string("Case keys to disable."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("familyID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object(["type": .string("string")]),
            "familyID": .object(["type": .string("string")]),
            "defaultTier": .object(["type": .string("string")]),
            "defaultPoints": .object(["type": .string("integer")]),
            "enabledCaseKeys": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
            ]),
            "validationStatus": .object(["type": .string("string")]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("familyID"), .string("defaultTier"),
            .string("defaultPoints"), .string("enabledCaseKeys"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let newTier = try Self.parseTier(input.defaultTier)
        let enable = Set(input.enableCases ?? [])
        let disable = Set(input.disableCases ?? [])
        guard newTier != nil || input.defaultPoints != nil || !enable.isEmpty || !disable.isEmpty else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "Specify at least one of: defaultTier, defaultPoints, enableCases, disableCases.")
        }
        guard enable.isDisjoint(with: disable) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "A case key cannot be in both enableCases and disableCases.")
        }

        guard let assignment = try await assignmentByPublicID(input.assignmentPublicID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "No assignment found with public ID \"\(input.assignmentPublicID)\".")
        }
        try await context.authorizeCourseAccess(assignment.courseID, tool: Self.name)
        guard let setup = try await APITestSetup.find(assignment.testSetupID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "The assignment's test setup could not be found.")
        }

        var payload = buildSuitePayload(fromManifest: setup.manifest, zipPath: setup.zipPath)
        guard
            let idx = payload.items.firstIndex(where: {
                $0.kind == "family" && $0.family?.id == input.familyID
            }),
            let family = payload.items[idx].family
        else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "No pattern family with id \"\(input.familyID)\" in the suite.")
        }

        let caseKeys = Set(family.cases.map(\.key))
        let unknown = enable.union(disable).subtracting(caseKeys)
        guard unknown.isEmpty else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "Unknown case key(s): \(unknown.sorted().joined(separator: ", ")).")
        }

        let updatedFamily = Self.rebuild(
            family, newTier: newTier, newPoints: input.defaultPoints, enable: enable, disable: disable)
        payload.items[idx].family = updatedFamily

        try await applySuiteEdit(setup: setup, body: payload, on: context.db)
        await scheduleValidationAfterSuiteEdit(req: context.request, assignment: assignment)

        return Output(
            assignmentPublicID: assignment.publicID,
            familyID: updatedFamily.id,
            defaultTier: updatedFamily.defaults.tier.rawValue,
            defaultPoints: updatedFamily.defaults.points,
            enabledCaseKeys: updatedFamily.cases.filter(\.enabled).map(\.key),
            validationStatus: assignment.validationStatus)
    }

    /// Reconstructs the family with new defaults and per-case enabled flags;
    /// every other field is copied verbatim.
    private static func rebuild(
        _ family: PatternFamily, newTier: TestTier?, newPoints: Int?,
        enable: Set<String>, disable: Set<String>
    ) -> PatternFamily {
        let defaults = PatternDefaults(
            tier: newTier ?? family.defaults.tier,
            points: newPoints ?? family.defaults.points,
            hint: family.defaults.hint,
            tolerance: family.defaults.tolerance)
        let cases = family.cases.map { caseSpec -> PatternCase in
            let enabled =
                enable.contains(caseSpec.key)
                ? true : (disable.contains(caseSpec.key) ? false : caseSpec.enabled)
            return PatternCase(
                key: caseSpec.key, label: caseSpec.label, args: caseSpec.args,
                expected: caseSpec.expected, argsProvided: caseSpec.argsProvided,
                argVarRefs: caseSpec.argVarRefs, hint: caseSpec.hint, tier: caseSpec.tier,
                points: caseSpec.points, enabled: enabled)
        }
        return PatternFamily(
            id: family.id, name: family.name, kind: family.kind, functionName: family.functionName,
            paramNames: family.paramNames, defaults: defaults, cases: cases,
            variables: family.variables, dependsOn: family.dependsOn)
    }

    private static func parseTier(_ raw: String?) throws -> TestTier? {
        guard let raw else { return nil }
        guard let tier = TestTier(rawValue: raw) else {
            throw MCPToolError.invalidArguments(
                tool: name, detail: "defaultTier must be one of: public, release, secret, student.")
        }
        return tier
    }
}
