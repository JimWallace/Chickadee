// APIServer/MCP/Tools/SetAssignmentLanguageTool.swift
//
// Write tool: change the language an assignment declares, by assignment public
// ID. content:write, course-scoped.
//
// Every assignment declares its language when it is created (#1331), and
// nothing infers one afterwards. This tool is how an author changes that
// declaration. It applies the same rule as the web Language select
// (`changeDeclaredLanguage`, #2486): "none" is allowed, an upload-only language
// also sets upload-only submission and worker grading, and a change is refused
// once a pattern family or notebook check has generated a test.

import Core
import Fluent
import Foundation

struct SetAssignmentLanguageTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// An `AssignmentLanguage` raw value, or `noLanguageChoice`. Not enumerated here — the
        /// hand-typed copy of this list stopped at `cpp` when Racket shipped,
        /// while the `enum` in `inputSchema` (derived) accepted it. See
        /// `MCPLanguageProse`.
        let language: String
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let language: String
        /// Reported because an upload-only language sets them, so a caller
        /// sees the assignment's whole resulting shape in one response.
        let submissionMode: String
        let gradingMode: String
    }

    static let name = "set_assignment_language"
    static let description =
        "Change the language an assignment declares, by its public ID: "
        + "\(MCPLanguageProse.tokens), or \"\(noLanguageChoice)\" for a suite of plain shell scripts. "
        + "Every assignment declares its language when it is created "
        + "(create_assignment requires it); replacing the starter notebook or adding a script never "
        + "changes it. Declaring \(LanguageProse.uploadOnlyTokens) also sets submissionMode to "
        + "uploadOnly and gradingMode to worker, since those languages have no notebook workflow. "
        + "Because a language change rewrites every generated filename, declare the language BEFORE "
        + "authoring pattern families or notebook checks; the tool refuses a change once generated "
        + "tests exist. Read the current language from get_assignment."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "language": .object([
                "type": .string("string"),
                "enum": .array(
                    AssignmentLanguage.allCases.map { .string($0.rawValue) }
                        + [.string(noLanguageChoice)]),
                "description": .string(
                    "The assignment's language, or \"\(noLanguageChoice)\". "
                        + "\(LanguageProse.uploadOnlyTokens) also set submissionMode uploadOnly and "
                        + "gradingMode worker."),
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
            "gradingMode": MCPSchema.string,
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("language"), .string("submissionMode"),
            .string("gradingMode"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let language: AssignmentLanguage?
        do {
            language = try parseLanguageChoice(input.language)
        } catch let error as AppError {
            throw MCPToolError.invalidArguments(detail: error.reason)
        }
        // Which language an assignment is decides how every generated test
        // renders — lifecycle-shaped, so instructor-level like its neighbours.
        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, atLeast: .instructor)
        do {
            try await changeDeclaredLanguage(setup: setup, to: language, on: context.db)
        } catch let error as AppError {
            // A fixable refusal reads as an arguments error, not a 400.
            throw MCPToolError.invalidArguments(detail: error.reason)
        }
        let stored = setup.decodedManifest()
        return Output(
            assignmentPublicID: assignment.publicID,
            language: stored?.language?.rawValue ?? noLanguageChoice,
            submissionMode: (stored?.submissionMode ?? .notebook).rawValue,
            gradingMode: (stored?.gradingMode ?? .worker).rawValue)
    }
}
