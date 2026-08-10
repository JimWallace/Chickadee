// APIServer/MCP/Tools/SetAssignmentLanguageTool.swift
//
// Write tool: declare the language an assignment is authored and graded in, by
// assignment public ID. content:write, course-scoped.
//
// For a language with an editor kernel the language is DERIVED, not declared —
// a notebook's kernelspec or a graded script's extension answers it, and the
// recorded manifest field is only a memo of that. This tool exists for the case
// derivation cannot reach: C++ has no editor kernel (so no kernelspec implies
// it) and its generated tests are deliberately extension-free `.sh` wrappers
// (so no filename implies it either). Without a declaration there is no way to
// author a C++ assignment through MCP at all.
//
// Declaring one of the derivable languages is still allowed and still useful —
// it pins an assignment whose suite is all pattern families, with no `.R`/`.lua`
// script on disk to find — it is simply not the case that motivated the tool.

import Core
import Fluent
import Foundation

struct SetAssignmentLanguageTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// An `AssignmentLanguage` raw value. Not enumerated here — the
        /// hand-typed copy of this list stopped at `cpp` when Racket shipped,
        /// while the `enum` in `inputSchema` (derived) accepted it. See
        /// `MCPLanguageProse`.
        let language: String
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let language: String
        /// Reported because an upload-only language constrains it, so a caller
        /// sees the assignment's whole resulting shape in one response.
        let submissionMode: String
    }

    static let name = "set_assignment_language"
    static let description =
        "Declare the language an assignment is authored and graded in by its public ID: "
        + "\(MCPLanguageProse.tokens). For every language except "
        + "\(LanguageProse.mustDeclareTokens) this is normally unnecessary — the "
        + "language is derived from the starter notebook's kernel or a graded script's extension — but "
        + "declaring it "
        + "pins a suite made only of pattern families, which has no script on disk to derive from. For "
        + "\(LanguageProse.mustDeclareTokens) it is required: its generated tests are shell wrappers "
        + "carrying no language extension, so nothing in the suite implies the language. A "
        + "\(LanguageProse.uploadOnlyTokens) assignment must already be uploadOnly "
        + "(set_submission_mode) — this tool refuses otherwise. Because a language change rewrites every "
        + "generated filename, declare the language BEFORE authoring pattern families or notebook checks; "
        + "the tool refuses a change once generated tests exist. Read the current language from "
        + "get_assignment."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "language": .object([
                "type": .string("string"),
                "enum": .array(
                    AssignmentLanguage.allCases.map { .string($0.rawValue) }),
                "description": .string(
                    "The assignment's language. \(LanguageProse.uploadOnlyTokens) additionally "
                        + "require submissionMode uploadOnly."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("language")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "language": MCPSchema.string,
            "submissionMode": MCPSchema.string,
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("language"), .string("submissionMode"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let raw = input.language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let parsed = AssignmentLanguage(rawValue: raw) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: unknownLanguageMessage(input.language))
        }
        // Which language an assignment is decides how every generated test
        // renders — lifecycle-shaped, so instructor-level like its neighbours.
        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, tool: Self.name, atLeast: .instructor)
        // Surface the shared helper's refusals as arguments errors; the helper
        // keeps its own guards for any path that skips this one.
        if requiresUploadOnlySubmission(parsed),
            currentManifestSubmissionMode(setup.manifest) != SubmissionMode.uploadOnly.rawValue,
            currentManifestLanguage(setup.manifest) != raw
        {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: requiresUploadOnlyMessage(parsed))
        }
        if currentManifestLanguage(setup.manifest) != raw,
            manifestHasGeneratedScripts(setup.manifest)
        {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: languageChangeAfterGenerationMessage)
        }
        let effective = try await setManifestLanguage(setup: setup, to: raw, on: context.db)
        return Output(
            assignmentPublicID: assignment.publicID,
            language: effective,
            submissionMode: currentManifestSubmissionMode(setup.manifest))
    }
}
