// APIServer/MCP/Tools/PreviewPersonalizationTool.swift
//
// Read tool: previews what a student with a given seed would see for an
// assignment's personalization — the resolved `name → Python-literal` values
// (literals + per-seed-evaluated expressions) and a `{{placeholder}}` audit of
// the starter notebook (which placeholders resolve, which don't).  content:read,
// course-scoped.
//
// Drives the same `PersonalizationSubstitution.resolve` the student first-open
// path uses, so the preview matches reality. When no seed is supplied it uses
// the acting account's own per-assignment seed (deterministic). Read-only: it
// evaluates expressions in the sandboxed `python3` subprocess but writes
// nothing.

import Core
import Fluent
import Foundation

struct PreviewPersonalizationTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// Optional hex seed to preview a specific student. When omitted, the
        /// acting account's own per-assignment seed is used.
        let seedHex: String?
    }

    struct Output: Encodable, Sendable {
        struct ResolvedValue: Encodable, Sendable {
            let name: String
            /// The Python literal substituted into `{{name}}`.
            let value: String
        }
        struct Placeholders: Encodable, Sendable {
            /// `{{name}}` markers found in the starter notebook.
            let used: [String]
            /// Used markers with no matching declared input (would fail at save).
            let unresolved: [String]
        }
        let assignmentPublicID: String
        /// The seed actually used (nil when the assignment has no expressions
        /// and no seed was supplied — only literals were resolved).
        let seedHex: String?
        let values: [ResolvedValue]
        /// Expression names that evaluated for this seed.
        let evaluatedExpressionNames: [String]
        /// Non-nil when expression evaluation failed (values then carry literals only).
        let evaluationError: String?
        let placeholders: Placeholders
    }

    static let name = "preview_personalization"
    static let description =
        "Preview what a student would see for an assignment's personalization, by public ID. Resolves "
        + "every global + section variable and evaluates the per-student expressions against a seed "
        + "(supply `seedHex` to preview a specific student; omitted uses your own seed), returning the "
        + "name→value map plus a starter-notebook `{{placeholder}}` audit (which resolve, which don't). "
        + "Read-only — runs the same resolution the student first-open path uses, but writes nothing."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "seedHex": .object([
                "type": .string("string"),
                "description": .string("Optional hex seed to preview a specific student."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object(["type": .string("string")]),
            "seedHex": .object(["type": .string("string")]),
            "values": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string")]),
                        "value": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("name"), .string("value")]),
                ]),
            ]),
            "evaluatedExpressionNames": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
            ]),
            "evaluationError": .object(["type": .string("string")]),
            "placeholders": .object([
                "type": .string("object"),
                "properties": .object([
                    "used": .object([
                        "type": .string("array"), "items": .object(["type": .string("string")]),
                    ]),
                    "unresolved": .object([
                        "type": .string("array"), "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("used"), .string("unresolved")]),
            ]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("values"),
            .string("evaluatedExpressionNames"), .string("placeholders"),
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
        guard let manifest = setup.decodedManifest() else {
            throw MCPToolError.executionFailed(tool: Self.name, detail: "Manifest is not valid JSON.")
        }

        let seedHex = try await resolveSeed(
            input: input, assignment: assignment, manifest: manifest, context: context)

        let supportDir = context.request.application.testSetupsDirectory + "shared/\(assignment.testSetupID)/"
        let resolution = await PersonalizationSubstitution.resolve(
            manifest: manifest, seedHex: seedHex, supportFilesDirectory: supportDir)

        let placeholders = Self.placeholderAudit(manifest: manifest, setup: setup, resolution: resolution)
        let values = resolution.substitutions
            .map { Output.ResolvedValue(name: $0.key, value: $0.value) }
            .sorted { $0.name < $1.name }

        return Output(
            assignmentPublicID: assignment.publicID,
            seedHex: seedHex,
            values: values,
            evaluatedExpressionNames: resolution.evaluatedExpressionNames.sorted(),
            evaluationError: resolution.evaluationError,
            placeholders: placeholders)
    }

    /// The seed to preview with: the explicit `seedHex` (validated as hex) when
    /// supplied; otherwise the acting account's own per-assignment seed, but
    /// only when the assignment actually declares expressions (literal-only
    /// assignments need no seed).
    private func resolveSeed(
        input: Input, assignment: APIAssignment, manifest: TestProperties, context: ToolContext
    ) async throws -> String? {
        if let provided = input.seedHex {
            let trimmed = provided.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.allSatisfy(\.isHexDigit) else {
                throw MCPToolError.invalidArguments(
                    tool: Self.name, detail: "seedHex must be a non-empty hexadecimal string.")
            }
            return trimmed.lowercased()
        }
        // No seed is needed for a literal-only assignment.
        let hasExpressions =
            !manifest.globalExpressions.isEmpty
            || manifest.sections.contains { !$0.expressions.isEmpty }
        guard hasExpressions else { return nil }
        let actingUser = try await context.requireEligibleSubject(tool: Self.name)
        guard let userID = actingUser.id, let assignmentID = assignment.id else { return nil }
        return try await AssignmentSeedStore.ensureSeed(
            userID: userID, assignmentID: assignmentID, on: context.db)
    }

    private static func placeholderAudit(
        manifest: TestProperties, setup: APITestSetup, resolution: PersonalizationSubstitution.Resolution
    ) -> Output.Placeholders {
        guard let starterName = manifest.starterNotebook,
            let notebookData = extractZipEntry(zipPath: setup.zipPath, entryName: starterName)
        else {
            return Output.Placeholders(used: [], unresolved: [])
        }
        let used = NotebookSubstitution.placeholderNames(in: notebookData)
        let resolved = Set(resolution.substitutions.keys)
        let unresolved = used.filter { !resolved.contains($0) }
        return Output.Placeholders(used: used.sorted(), unresolved: unresolved.sorted())
    }
}
