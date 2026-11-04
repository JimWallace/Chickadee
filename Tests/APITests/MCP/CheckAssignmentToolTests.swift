// Tests for CheckAssignmentTool (#2747), backed by a real test database. The
// checks themselves are tested in `AuthoringCheckTests`; these cover the tool:
// it loads the stored manifest, runs the whole catalog and reports an
// undecodable manifest as a finding.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct CheckAssignmentToolTests {
    private let manifest = """
        {"schemaVersion":1,"testSuites":[\
        {"tier":"release","script":"test_a.sh","points":0},\
        {"tier":"secret","script":"test_b.sh","points":3}\
        ],"timeLimitSeconds":10}
        """

    @Test func reportsTheCatalogFindingsForTheStoredManifest() async throws {
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(on: app, setupID: "setup_chk", manifest: manifest)
            let output = try await CheckAssignmentTool().execute(
                .init(assignmentPublicID: assignment.publicID), mcpContext(app, scopes: [.read]))
            #expect(output.assignmentPublicID == assignment.publicID)
            #expect(output.checksRun == AuthoringCheckCatalog.ids)
            #expect(output.findings.map(\.checkID) == ["tiers.noPublicTest", "points.zeroPoints"])
            #expect(output.findings.last?.location == .suiteItem("test_a.sh"))
        }
    }

    @Test func aCleanAssignmentHasNoFindingsButListsTheChecks() async throws {
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(
                on: app, setupID: "setup_chk_clean", manifest: TestManifests.workerOnePythonSuite)
            let output = try await CheckAssignmentTool().execute(
                .init(assignmentPublicID: assignment.publicID), mcpContext(app, scopes: [.read]))
            #expect(output.findings.isEmpty)
            #expect(!output.checksRun.isEmpty)
        }
    }

    @Test func anUndecodableManifestIsOneErrorFinding() async throws {
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(on: app, setupID: "setup_chk_bad", manifest: manifest)
            let setup = try #require(try await APITestSetup.find("setup_chk_bad", on: app.db))
            setup.manifest = "not json"
            try await setup.save(on: app.db)

            let output = try await CheckAssignmentTool().execute(
                .init(assignmentPublicID: assignment.publicID), mcpContext(app, scopes: [.read]))
            #expect(output.checksRun == [CheckAssignmentTool.undecodableManifestID])
            #expect(output.findings.map(\.severity) == [.error])
        }
    }

}

/// The declared schemas against the encoded types, with no database.
@Suite struct CheckAssignmentToolSchemaTests {
    private let finding = AuthoringFinding(
        checkID: "points.zeroPoints", source: .check, severity: .info,
        location: .suiteItem("test_a.sh"), message: "m", suggestedFix: "f")

    private func object(_ value: JSONValue?) throws -> [String: JSONValue] {
        guard case .object(let fields)? = value else { throw IssueRecorded("expected a JSON object schema") }
        return fields
    }

    private func encodedKeys(_ value: some Encodable) throws -> Set<String> {
        let decoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        return Set(try #require(decoded).keys)
    }

    private func required(_ schema: [String: JSONValue]) -> Set<String> {
        guard case .array(let names)? = schema["required"] else { return [] }
        return Set(names.compactMap { if case .string(let name) = $0 { name } else { nil } })
    }

    @Test func outputSchemaRequiresEveryOutputField() throws {
        let output = CheckAssignmentTool.Output(
            assignmentPublicID: "a", checksRun: ["x.y"], findings: [finding])
        let schema = try object(CheckAssignmentTool.outputSchema)
        #expect(required(schema) == (try encodedKeys(output)))
        #expect(Set(try object(schema["properties"]).keys) == (try encodedKeys(output)))
    }

    @Test func findingSchemaDeclaresEveryFindingField() throws {
        let schema = try object(CheckAssignmentTool.findingSchema)
        #expect(Set(try object(schema["properties"]).keys) == (try encodedKeys(finding)))
        #expect(required(schema) == (try encodedKeys(finding)).subtracting(["suggestedFix"]))
    }

    @Test func findingSchemaEnumsFollowAllCases() throws {
        let properties = try object(try object(CheckAssignmentTool.findingSchema)["properties"])
        let location = try object(try object(properties["location"])["properties"])
        #expect(try object(properties["severity"])["enum"] == MCPEnumProse<AuthoringFinding.Severity>.jsonEnum)
        #expect(try object(properties["source"])["enum"] == MCPEnumProse<AuthoringFinding.Source>.jsonEnum)
        #expect(
            try object(location["kind"])["enum"] == MCPEnumProse<AuthoringFinding.Location.Kind>.jsonEnum)
    }
}
