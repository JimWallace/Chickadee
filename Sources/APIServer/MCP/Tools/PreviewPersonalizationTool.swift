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
            /// Per-student input names referenced anywhere: `{{name}}` markers in
            /// the starter notebook AND `$name` refs in pattern-family test-script
            /// cases (`argVarRefs` / `expectedVarRef`).
            let used: [String]
            /// Used names with no matching declared input (would fail at save).
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
            "assignmentPublicID": MCPSchema.assignmentPublicID,
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
            "assignmentPublicID": MCPSchema.string,
            "seedHex": MCPSchema.string,
            "values": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": MCPSchema.string,
                        "value": MCPSchema.string,
                    ]),
                    "required": .array([.string("name"), .string("value")]),
                ]),
            ]),
            "evaluatedExpressionNames": .object([
                "type": .string("array"), "items": MCPSchema.string,
            ]),
            "evaluationError": MCPSchema.string,
            "placeholders": .object([
                "type": .string("object"),
                "properties": .object([
                    "used": .object([
                        "type": .string("array"), "items": MCPSchema.string,
                    ]),
                    "unresolved": .object([
                        "type": .string("array"), "items": MCPSchema.string,
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
        let (assignment, setup) = try await context.authorizedAssignmentAndSetup(
            publicID: input.assignmentPublicID, tool: Self.name)
        guard let manifest = setup.decodedManifest() else {
            throw MCPToolError.executionFailed(tool: Self.name, detail: "Manifest is not valid JSON.")
        }

        let seedHex = try await resolveSeed(
            input: input, assignment: assignment, manifest: manifest, context: context)

        let supportDir = context.request.application.testSetupsDirectory + "shared/\(assignment.testSetupID)/"
        let resolution = await PersonalizationSubstitution.resolve(
            manifest: manifest, seedHex: seedHex, supportFilesDirectory: supportDir,
            language: AssignmentLanguage.resolve(manifest: manifest))

        let placeholders = Self.placeholderAudit(
            manifest: manifest, setup: setup, resolution: resolution)
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
        guard manifest.hasExpressions else { return nil }
        let actingUser = try await context.requireEligibleSubject(tool: Self.name)
        guard let userID = actingUser.id, let assignmentID = assignment.id else { return nil }
        // Acting-user seed bookkeeping runs on the owner pool, not the
        // least-privilege `.mcp` pool: `assignment_personalization_seeds` is
        // denied to the `chickadee_mcp` role. The notebook/expression content
        // this previews is still read through the `.mcp`-backed paths.
        return try await AssignmentSeedStore.ensureSeed(
            userID: userID, assignmentID: assignmentID, on: context.mainDB)
    }

    private static func placeholderAudit(
        manifest: TestProperties, setup: APITestSetup,
        resolution: PersonalizationSubstitution.Resolution
    ) -> Output.Placeholders {
        var used = Set<String>()

        // 1. Notebook `{{name}}` placeholders. Read the notebook the student
        // actually opens: `notebookData(for:)` prefers the standalone
        // `notebookPath` blob — what `update_notebook`, the editor, and the
        // student first-open path all use — and only falls back to the zip's
        // starter entry. (Before #811 this read the zip and missed markers added
        // via `update_notebook`, which writes `notebookPath`, not the zip entry.)
        if let notebookData = try? notebookData(for: setup) {
            used.formUnion(NotebookSubstitution.placeholderNames(in: notebookData))
        }

        // 2. Test-script per-student refs: a pattern-family case may reference a
        // per-student input via `$name` (argVarRefs) or `expectedVarRef`. Report
        // those too so the audit covers grading, not just the notebook.
        for family in manifest.patternFamilies {
            for c in family.cases {
                for ref in c.argVarRefs.compactMap({ $0 }) { used.insert(ref) }
                if let expectedRef = c.expectedVarRef, !expectedRef.isEmpty {
                    used.insert(expectedRef)
                }
            }
        }

        let resolved = Set(resolution.substitutions.keys)
        let unresolved = used.filter { !resolved.contains($0) }
        return Output.Placeholders(used: used.sorted(), unresolved: unresolved.sorted())
    }
}
