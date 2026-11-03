// APIServer/MCP/Tools/CheckAssignmentTool.swift
//
// Read tool: runs the rule-based authoring checks (`AuthoringCheckCatalog`)
// over an assignment's stored content and returns their findings, by public
// ID. content:read, course-scoped (#2747).
//
// The checks read stored content only. This tool enqueues no run and writes
// nothing. A model reviewer calls it first, so that it reviews only what a
// rule cannot find, and reports in the same `AuthoringFinding` format.

import Core
import Fluent
import Foundation

struct CheckAssignmentTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        /// The id of every check that ran, in run order. A check that found
        /// nothing is still listed, so an empty `findings` is a real result.
        let checksRun: [String]
        /// Most severe first.
        let findings: [AuthoringFinding]
    }

    /// The finding for a stored manifest that does not decode. No other check
    /// can run then.
    static let undecodableManifestID = "manifest.undecodable"

    static let name = "check_assignment"
    static let description =
        "Run the rule-based authoring checks over an assignment's stored content, by public ID, and "
        + "return their findings, most severe first. Each finding has a checkID, a severity ("
        + MCPEnumProse<AuthoringFinding.Severity>.slashAlternatives + "), a location ("
        + MCPEnumProse<AuthoringFinding.Location.Kind>.slashAlternatives + ", with a reference such as "
        + "the script filename), a message and an optional suggestedFix. checksRun lists every check "
        + "that ran, so an empty findings list means none of them found a problem. Read-only: the "
        + "checks read the stored content, start no runner job and change nothing. Call it before "
        + "reviewing an assignment, and do not repeat its findings. A reviewer that reports its own "
        + "findings uses the same format with source \"reviewer\"."
    static let inputSchema: JSONValue = MCPSchema.assignmentPublicIDOnlyInput
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "checksRun": .object([
                "type": .string("array"),
                "items": MCPSchema.string,
            ]),
            "findings": .object([
                "type": .string("array"),
                "items": findingSchema,
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("checksRun"), .string("findings")]),
    ])
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let (assignment, setup) = try await context.authorizedAssignmentAndSetup(
            publicID: input.assignmentPublicID)
        guard let manifest = setup.decodedManifest() else {
            return Output(
                assignmentPublicID: assignment.publicID,
                checksRun: [Self.undecodableManifestID],
                findings: [
                    AuthoringFinding(
                        checkID: Self.undecodableManifestID, source: .check, severity: .error,
                        location: .assignment,
                        message: "The stored test.properties.json does not decode, so no other check could run.")
                ])
        }
        let snapshot = AuthoringSnapshot(manifest: manifest)
        return Output(
            assignmentPublicID: assignment.publicID,
            checksRun: AuthoringCheckCatalog.ids,
            findings: AuthoringCheckCatalog.findings(in: snapshot))
    }

    /// The JSON Schema for one `AuthoringFinding`.
    static let findingSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "checkID": MCPSchema.string,
            "source": .object([
                "type": .string("string"),
                "enum": MCPEnumProse<AuthoringFinding.Source>.jsonEnum,
            ]),
            "severity": .object([
                "type": .string("string"),
                "enum": MCPEnumProse<AuthoringFinding.Severity>.jsonEnum,
            ]),
            "location": .object([
                "type": .string("object"),
                "properties": .object([
                    "kind": .object([
                        "type": .string("string"),
                        "enum": MCPEnumProse<AuthoringFinding.Location.Kind>.jsonEnum,
                    ]),
                    "reference": .object([
                        "type": .string("string"),
                        "description": .string(
                            "suiteItem: the script filename. notebookCell: the 0-based cell index. "
                                + "input: the input name. file: the filename. Absent for assignment."),
                    ]),
                ]),
                "required": .array([.string("kind")]),
            ]),
            "message": MCPSchema.string,
            "suggestedFix": MCPSchema.string,
        ]),
        "required": .array([
            .string("checkID"), .string("source"), .string("severity"), .string("location"), .string("message"),
        ]),
    ])
}
