// APIServer/MCP/Tools/ReflectionFeedbackTools.swift
//
// The three AI-assisted feedback tools (docs/ai-assisted-feedback.md):
// list_reflections, get_reflections and draft_feedback. An instructor's agent
// reads students' written reasoning by pseudonymous handle and drafts
// feedback. Course staff review and release every draft on the web; no tool
// here can release one, and no tool anywhere can turn the feature on.
//
// Every call authorizes course staff (TA+) in a course that is not archived,
// then passes `MCPStudentDataBoundary.gatedFeedbackSetup`, which requires both
// gates. The tools never see a user id, a name, a grade, a result or the
// student's code.

import Core
import Foundation

/// One student as `list_reflections` reports them.
struct MCPReflectionListEntry: Encodable, Sendable {
    let handle: String
    let feedbackState: String
}

struct ListReflectionsTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let reflectionPromptCount: Int
        let students: [MCPReflectionListEntry]
    }

    static let name = "list_reflections"
    static let description =
        "List the students who have submitted to an assignment with AI-assisted feedback turned on, "
        + "by pseudonymous handle (for example R-7Q2M4K), with each one's feedback state: none, draft, "
        + "released, discarded or stale (the student submitted again after the feedback was written). "
        + "reflectionPromptCount is how many starter-notebook cells carry the `reflection` tag. Names "
        + "and other identity are never returned. The assignment's course and the assignment itself must "
        + "have AI-assisted feedback turned on by a person on the web, and the account must be course "
        + "staff. Use get_reflections to read one student's written answers."
    static let inputSchema: JSONValue = MCPSchema.assignmentPublicIDOnlyInput
    static let outputSchema: JSONValue? = MCPSchema.object(
        properties: [
            "assignmentPublicID": MCPSchema.string,
            "reflectionPromptCount": MCPSchema.integer,
            "students": .object([
                "type": .string("array"),
                "items": MCPSchema.object(
                    properties: [
                        "handle": MCPSchema.string,
                        "feedbackState": feedbackStateSchema,
                    ],
                    required: ["handle", "feedbackState"], additionalProperties: nil),
            ]),
        ],
        required: ["assignmentPublicID", "reflectionPromptCount", "students"],
        additionalProperties: nil)
    static let requiredScopes: Set<ContentScope> = [.feedbackRead]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let assignment = try await context.authorizedAssignmentForWrite(
            publicID: input.assignmentPublicID, atLeast: .ta)
        let setup = try await MCPStudentDataBoundary.gatedFeedbackSetup(for: assignment, on: context.db)
        let subjects = try await MCPStudentDataBoundary.feedbackSubjects(for: assignment, on: context.db)
        let promptCount = await ReflectionFeedbackService.reflections(setup: setup, submission: nil).count
        return Output(
            assignmentPublicID: assignment.publicID,
            reflectionPromptCount: promptCount,
            students: subjects.map {
                MCPReflectionListEntry(handle: $0.handle, feedbackState: $0.state.rawValue)
            })
    }
}

struct GetReflectionsTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        let handle: String
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let handle: String
        let feedbackState: String
        let draftText: String?
        let reflections: [ReflectionPair]
    }

    static let name = "get_reflections"
    static let description =
        "Read one student's written answers in an assignment with AI-assisted feedback turned on, by "
        + "the pseudonymous handle list_reflections returns. Each entry pairs a prompt (the markdown "
        + "cell before a `reflection`-tagged cell, read from the starter notebook, so the student cannot "
        + "change it) with the student's response from their latest submission (null when the "
        + "submission has no matching cell). Also returns the current feedback state and any draft "
        + "text. The student's code, outputs, test results, grade and identity are never returned."
    static let inputSchema: JSONValue = MCPSchema.object(
        properties: [
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "handle": handleSchema,
        ],
        required: ["assignmentPublicID", "handle"])
    static let outputSchema: JSONValue? = MCPSchema.object(
        properties: [
            "assignmentPublicID": MCPSchema.string,
            "handle": MCPSchema.string,
            "feedbackState": feedbackStateSchema,
            "draftText": MCPSchema.nullableString,
            "reflections": .object([
                "type": .string("array"),
                "items": MCPSchema.object(
                    properties: [
                        "index": MCPSchema.integer,
                        "prompt": MCPSchema.string,
                        "response": MCPSchema.nullableString,
                    ],
                    required: ["index", "prompt"], additionalProperties: nil),
            ]),
        ],
        required: ["assignmentPublicID", "handle", "feedbackState", "reflections"],
        additionalProperties: nil)
    static let requiredScopes: Set<ContentScope> = [.feedbackRead]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let assignment = try await context.authorizedAssignmentForWrite(
            publicID: input.assignmentPublicID, atLeast: .ta)
        let setup = try await MCPStudentDataBoundary.gatedFeedbackSetup(for: assignment, on: context.db)
        let (subject, reflections) = try await MCPStudentDataBoundary.feedbackReflections(
            handle: input.handle, assignment: assignment, setup: setup, on: context.db)
        return Output(
            assignmentPublicID: assignment.publicID,
            handle: subject.handle,
            feedbackState: subject.state.rawValue,
            draftText: subject.draftText,
            reflections: reflections)
    }
}

struct DraftFeedbackTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        let handle: String
        let feedback: String
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let handle: String
        let feedbackState: String
    }

    static let name = "draft_feedback"
    static let description =
        "Save draft feedback on one student's written answers, by pseudonymous handle, in an assignment "
        + "with AI-assisted feedback turned on. The draft is NOT shown to the student: course staff "
        + "review, edit and release it on the web. Saving replaces any earlier draft. It is refused when "
        + "the student's feedback is already released and current. feedback is plain text, at most "
        + "\(ReflectionFeedbackService.maxDraftLength) characters. The feedback carries no score and "
        + "does not change a grade."
    static let inputSchema: JSONValue = MCPSchema.object(
        properties: [
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "handle": handleSchema,
            "feedback": .object([
                "type": .string("string"),
                "maxLength": .int(ReflectionFeedbackService.maxDraftLength),
                "description": .string("The draft feedback, as plain text, for course staff to review."),
            ]),
        ],
        required: ["assignmentPublicID", "handle", "feedback"])
    static let outputSchema: JSONValue? = MCPSchema.object(
        properties: [
            "assignmentPublicID": MCPSchema.string,
            "handle": MCPSchema.string,
            "feedbackState": feedbackStateSchema,
        ],
        required: ["assignmentPublicID", "handle", "feedbackState"],
        additionalProperties: nil)
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.feedbackWrite]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        if let refusal = ReflectionFeedbackService.refusal(forDraft: input.feedback) {
            throw MCPToolError.invalidArguments(detail: refusal)
        }
        let assignment = try await context.authorizedAssignmentForWrite(
            publicID: input.assignmentPublicID, atLeast: .ta)
        _ = try await MCPStudentDataBoundary.gatedFeedbackSetup(for: assignment, on: context.db)
        let subject = try await MCPStudentDataBoundary.saveFeedbackDraft(
            handle: input.handle, text: input.feedback, assignment: assignment,
            clientName: context.actingClientName, on: context.db)
        return Output(
            assignmentPublicID: assignment.publicID,
            handle: subject.handle,
            feedbackState: subject.state.rawValue)
    }
}

private let handleSchema: JSONValue = .object([
    "type": .string("string"),
    "description": .string("A pseudonymous student handle from list_reflections, for example R-7Q2M4K."),
])

private let feedbackStateSchema: JSONValue = .object([
    "type": .string("string"),
    "enum": .array(ReflectionFeedbackState.allCases.map { .string($0.rawValue) }),
])
