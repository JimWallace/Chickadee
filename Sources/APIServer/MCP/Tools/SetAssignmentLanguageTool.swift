// APIServer/MCP/Tools/SetAssignmentLanguageTool.swift
//
// Write tool: change the language an assignment declares, by assignment public
// ID. content:write, course-scoped.
//
// Every assignment declares its language when it is created (#1331), and
// nothing infers one afterwards. This tool is how an author changes that
// declaration. Because the language decides every generated filename, it
// refuses a change once a pattern family or notebook check has generated a
// test.

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
        "Change the language an assignment declares, by its public ID: "
        + "\(MCPLanguageProse.tokens). Every assignment declares its language when it is created "
        + "(create_assignment requires it); replacing the starter notebook or adding a script never "
        + "changes it. A "
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
            throw MCPToolError.invalidArguments(detail: unknownLanguageMessage(input.language))
        }
        // Which language an assignment is decides how every generated test
        // renders — lifecycle-shaped, so instructor-level like its neighbours.
        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, atLeast: .instructor)
        // Surface the shared helper's refusals as arguments errors; the helper
        // keeps its own guards for any path that skips this one.
        if requiresUploadOnlySubmission(parsed),
            currentManifestSubmissionMode(setup.manifest) != SubmissionMode.uploadOnly.rawValue,
            currentManifestLanguage(setup.manifest) != raw
        {
            throw MCPToolError.invalidArguments(detail: requiresUploadOnlyMessage(parsed))
        }
        if currentManifestLanguage(setup.manifest) != raw,
            manifestHasGeneratedScripts(setup.manifest)
        {
            throw MCPToolError.invalidArguments(detail: languageChangeAfterGenerationMessage)
        }
        let effective = try await setManifestLanguage(setup: setup, to: raw, on: context.db)
        return Output(
            assignmentPublicID: assignment.publicID,
            language: effective,
            submissionMode: currentManifestSubmissionMode(setup.manifest))
    }
}
