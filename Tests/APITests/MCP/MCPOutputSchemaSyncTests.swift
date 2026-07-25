// Drift guards for the tool catalog's declared output schemas (#1121).  Every
// `outputSchema` hand-mirrors its tool's `Output` struct, so adding a field to
// the struct without touching the schema used to drift silently — the client
// sees `structuredContent` keys the advertised schema never mentions.  Two
// guards: a structural check over the whole catalog (well-formed object
// schemas, `required` ⊆ `properties`), and a key-level sync check that encodes
// a fully-populated representative `Output` per drift-prone tool and compares
// its keys against the declared schema.

import Core
import Testing

@testable import APIServer

@Suite struct MCPOutputSchemaSyncTests {
    private let tools = MCPToolCatalog.live.all

    /// Every advertised schema (input and output) must be a well-formed object
    /// schema whose `required` names all exist in `properties` — the mistake a
    /// hand-edited literal most commonly introduces.
    @Test func everySchemaIsWellFormedAndRequiredKeysExist() throws {
        for tool in tools {
            for (label, schema) in [("inputSchema", tool.inputSchema), ("outputSchema", tool.outputSchema ?? .null)]
            where schema != .null {
                guard case .object(let fields) = schema else {
                    Issue.record("\(tool.name) \(label) is not a JSON object")
                    continue
                }
                #expect(fields["type"] == .string("object"), "\(tool.name) \(label) must declare type:object")
                guard case .object(let properties)? = fields["properties"] else {
                    Issue.record("\(tool.name) \(label) declares no properties object")
                    continue
                }
                if label == "outputSchema" {
                    #expect(!properties.isEmpty, "\(tool.name) outputSchema has no properties")
                }
                if case .array(let required)? = fields["required"] {
                    for name in required {
                        guard case .string(let key) = name else {
                            Issue.record("\(tool.name) \(label) required entry is not a string")
                            continue
                        }
                        #expect(
                            properties[key] != nil,
                            "\(tool.name) \(label) requires \"\(key)\" but never declares it as a property")
                    }
                }
            }
        }
    }

    /// Encodes a fully-populated representative `Output` for the drift-prone
    /// (write/content-edit) tools and checks its keys against the declared
    /// schema: every encoded key must be declared, and every `required` key
    /// must be present in the encoding.
    @Test func representativeOutputsMatchDeclaredSchemas() throws {
        let cases: [(name: String, schema: JSONValue?, output: any Encodable & Sendable)] = [
            (
                SetGradingModeTool.name, SetGradingModeTool.outputSchema,
                SetGradingModeTool.Output(assignmentPublicID: "abc123", gradingMode: "worker")
            ),
            (
                SetTimeLimitTool.name, SetTimeLimitTool.outputSchema,
                SetTimeLimitTool.Output(assignmentPublicID: "abc123", timeLimitSeconds: 10)
            ),
            (
                SetDatasetTool.name, SetDatasetTool.outputSchema,
                SetDatasetTool.Output(
                    assignmentPublicID: "abc123",
                    datasets: [SetDatasetTool.DatasetEntry(file: "cases.csv", sampleSize: 100)])
            ),
            (
                SetMinimumRunnerVersionTool.name, SetMinimumRunnerVersionTool.outputSchema,
                SetMinimumRunnerVersionTool.Output(
                    assignmentPublicID: "abc123", minimumRunnerVersion: "0.5.0")
            ),
            (
                AuthorScriptTool.name, AuthorScriptTool.outputSchema,
                AuthorScriptTool.Output(
                    assignmentPublicID: "abc123", filename: "test_x.py", tier: "public",
                    isTest: true, created: true, validationStatus: "pending", assignmentClosed: true)
            ),
            (
                DeleteSuiteItemTool.name, DeleteSuiteItemTool.outputSchema,
                DeleteSuiteItemTool.Output(
                    assignmentPublicID: "abc123", kind: "script", removed: "test_x.py",
                    remainingItemCount: 3, validationStatus: "pending", assignmentClosed: true)
            ),
            (
                UpdateSolutionTool.name, UpdateSolutionTool.outputSchema,
                UpdateSolutionTool.Output(
                    assignmentPublicID: "abc123", cellCount: 4,
                    validationStatus: "pending", assignmentClosed: true)
            ),
            (
                GetServerInfoTool.name, GetServerInfoTool.outputSchema,
                GetServerInfoTool.Output(
                    version: "0.0.0", mcpMode: "read_write",
                    advertisedScopes: ["content:read"], writeEnabled: true)
            ),
            (
                CloneAssignmentTool.name, CloneAssignmentTool.outputSchema,
                CloneAssignmentTool.Output(
                    publicID: "abc123", title: "T", slug: "t", courseCode: "CS136",
                    sourceAssignmentPublicID: "def456", isOpen: false, validationStatus: "pending")
            ),
            (
                CreateAssignmentTool.name, CreateAssignmentTool.outputSchema,
                CreateAssignmentTool.Output(
                    publicID: "abc123", title: "T", slug: "t", courseCode: "CS136",
                    cellCount: 2, isOpen: false)
            ),
            (
                UpdateAssignmentTool.name, UpdateAssignmentTool.outputSchema,
                UpdateAssignmentTool.Output(
                    publicID: "abc123", title: "T", slug: "t", isOpen: true,
                    visibility: "open", dueAt: "2026-01-01T00:00:00Z",
                    startsAt: "2026-01-01T00:00:00Z", validationStatus: "passed",
                    secretRevealEnabled: false)
            ),
        ]

        for testCase in cases {
            let schema = try #require(testCase.schema, "\(testCase.name) declares no outputSchema")
            guard case .object(let fields) = schema,
                case .object(let properties)? = fields["properties"]
            else {
                Issue.record("\(testCase.name) outputSchema is not an object schema")
                continue
            }
            let encoded = try JSONValue(encoding: testCase.output)
            guard case .object(let encodedFields) = encoded else {
                Issue.record("\(testCase.name) representative Output did not encode to an object")
                continue
            }
            let declaredKeys = Set(properties.keys)
            let encodedKeys = Set(encodedFields.keys)
            // A fully-populated Output must encode exactly the declared keys:
            // an extra encoded key means the struct gained a field the schema
            // never learned about; a missing one means the schema advertises a
            // field the tool no longer returns.
            #expect(
                encodedKeys == declaredKeys,
                "\(testCase.name): Output keys \(encodedKeys.sorted()) != declared outputSchema properties \(declaredKeys.sorted())"
            )
            if case .array(let required)? = fields["required"] {
                for name in required {
                    if case .string(let key) = name {
                        #expect(
                            encodedFields[key] != nil,
                            "\(testCase.name): required key \"\(key)\" absent from the representative Output")
                    }
                }
            }
        }
    }
}
