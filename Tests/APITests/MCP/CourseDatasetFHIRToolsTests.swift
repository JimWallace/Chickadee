// Tests/APITests/MCP/CourseDatasetFHIRToolsTests.swift
//
// The MCP dataset tools with a FHIR NDJSON dataset (docs/fhir-datasets-plan.md
// §7, P3). create_dataset takes a format and refuses a filename of the other
// one, naming `format`. list_datasets reports the format, and get_dataset
// also the FHIR summary and resource lines with no header (5 by default).
// update_dataset describes a FHIR dataset by entries and an example, and
// refuses columns on it (and entries on a CSV). get_support_files and
// get_assignment report the attachment's format. Every result validates
// against the tool's declared output schema.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

/// The attach path runs `zip` and `unzip`, so the suite has a time limit.
@Suite(.serialized, .timeLimit(.minutes(5))) final class CourseDatasetFHIRToolsTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-dataset-fhir-tools")
    }

    private static let feed =
        [
            #"{"resourceType":"Patient","id":"p1"}"#,
            #"{"resourceType":"Patient","id":"p2"}"#,
            #"{"resourceType":"Observation","id":"o1","subject":{"reference":"Patient/p1"},"#
                + #""code":{"coding":[{"system":"http://loinc.org","code":"8310-5"}]}}"#,
            #"{"resourceType":"Observation","id":"o2","subject":{"reference":"Patient/p2"},"#
                + #""code":{"coding":[{"system":"http://loinc.org","code":"8310-5"}]}}"#,
        ].joined(separator: "\n") + "\n"
    private static let csv = "id,ward\n1,A\n2,B\n"
    private static let staff = "fhir_tools_staff"

    private func context() -> ToolContext {
        mcpContext(app, subject: Self.staff)
    }

    /// Course FHT1 with its instructor and one open assignment whose zip holds
    /// a test.
    private func fixture() async throws -> APIAssignment {
        let courseID = try await makeTestCourse(on: app, code: "FHT1").requireID()
        let staff = try await makeTestUser(on: app, username: Self.staff, role: "instructor")
        try await makeTestEnrollment(on: app, userID: staff.requireID(), courseID: courseID)
        let setupID = "fht_\(UUID().uuidString.prefix(8))"
        let manifest = """
            {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test_a.sh"}],\
            "timeLimitSeconds":10,"makefile":null,"submissionMode":"uploadOnly"}
            """
        try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: manifest, withNotebook: false, withZip: false)
        try await writeZipFixture(
            at: app.testSetupsDirectory + setupID + ".zip", entries: [("test_a.sh", "exit 0\n")])
        return try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
    }

    private func create(
        format: String?, url: String = "https://example.org/ed_feed.ndjson", body: String = feed,
        slug: String = "ed-feed"
    ) async throws -> CreateDatasetTool.Output {
        try await CreateDatasetTool(fetch: { _, _ in Data(body.utf8) }).execute(
            .init(
                courseCode: "FHT1", name: "ED feed", slug: slug, description: nil, provenance: nil, licence: nil,
                sourceUrl: url, note: nil, assignmentPublicID: nil, filename: nil, format: format),
            context())
    }

    private func update(
        slug: String = "ed-feed", columns: [UpdateDatasetTool.ColumnInput]? = nil,
        entries: [UpdateDatasetTool.EntryInput]? = nil, example: UpdateDatasetTool.ExampleInput? = nil
    ) async throws -> UpdateDatasetTool.Output {
        try await UpdateDatasetTool().execute(
            .init(
                courseCode: "FHT1", slug: slug, name: nil, description: nil, provenance: nil, licence: nil,
                isPublished: nil, columns: columns, entries: entries, example: example),
            context())
    }

    private func expectValid(_ output: some Encodable, against schema: JSONValue?, _ label: String) throws {
        let violations = MCPOutputSchemaValidator.violations(
            of: try JSONValue(encoding: output), against: try #require(schema))
        #expect(violations.isEmpty, "\(label): \(violations)")
    }

    // MARK: - create_dataset

    @Test func createDatasetMakesAFHIRDatasetByItsFormat() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            let out = try await create(format: "fhirNdjson")
            #expect(out.dataset.format == "fhirNdjson")
            #expect(out.dataset.columns.isEmpty)
            #expect(out.dataset.versions.map(\.rowCount) == [2])
            let summary = try #require(out.dataset.fhir)
            #expect(summary.patientCount == 2)
            #expect(summary.example?.id == "o1")
            try expectValid(out, against: CreateDatasetTool.outputSchema, "create_dataset")
        }
    }

    @Test func aFilenameOfTheOtherFormatIsRefusedByName() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            for (format, url) in [
                (nil as String?, "https://example.org/ed_feed.ndjson"),
                ("fhirNdjson", "https://example.org/wards.csv"),
                ("tsv", "https://example.org/wards.csv"),
            ] {
                do {
                    _ = try await create(format: format, url: url)
                    Issue.record("\(format ?? "nil") with \(url) was accepted")
                } catch let MCPToolError.invalidArguments(detail) {
                    #expect(detail.contains("format"), "\(detail)")
                }
            }
            #expect(try await CourseDatasetService.find(courseID: courseID(), slug: "ed-feed", on: app.db) == nil)
        }
    }

    private func courseID() async throws -> UUID {
        try #require(try await APICourse.query(on: app.db).filter(\.$code == "FHT1").first()).requireID()
    }

    // MARK: - Reading

    @Test func listAndGetReportTheFormatAndShowResourceLines() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            _ = try await create(format: "fhirNdjson")
            _ = try await create(format: nil, url: "https://example.org/wards.csv", body: Self.csv, slug: "wards")

            let list = try await ListDatasetsTool().execute(.init(courseCode: "FHT1"), context())
            #expect(
                Dictionary(uniqueKeysWithValues: list.datasets.map { ($0.slug, $0.format) })
                    == ["ed-feed": "fhirNdjson", "wards": "csv"])
            // A list leaves the summary to get_dataset.
            #expect(list.datasets.allSatisfy { $0.fhir == nil })
            try expectValid(list, against: ListDatasetsTool.outputSchema, "list_datasets")

            let lines = Self.feed.split(separator: "\n")
            let two = try await GetDatasetTool().execute(
                .init(courseCode: "FHT1", slug: "ed-feed", version: nil, maxRows: 2), context())
            #expect(two.rows == lines.prefix(2).joined(separator: "\n") + "\n")
            #expect(two.rowCount == 2)
            #expect(two.truncated)
            #expect(two.dataset.fhir?.patientCount == 2)
            try expectValid(two, against: GetDatasetTool.outputSchema, "get_dataset")

            let all = try await GetDatasetTool().execute(
                .init(courseCode: "FHT1", slug: "ed-feed", version: nil, maxRows: nil), context())
            #expect(all.rows == Self.feed)
            #expect(!all.truncated)

            // Five lines by default: a sixth resource is left out.
            let longer =
                Self.feed
                + Self.feed.replacingOccurrences(of: "\"p", with: "\"q")
                .replacingOccurrences(of: "\"o", with: "\"r")
            _ = try await AddDatasetVersionTool(fetch: { _, _ in Data(longer.utf8) }).execute(
                .init(
                    courseCode: "FHT1", slug: "ed-feed", sourceUrl: "https://example.org/ed_feed.ndjson",
                    filename: nil, note: nil),
                context())
            let defaulted = try await GetDatasetTool().execute(
                .init(courseCode: "FHT1", slug: "ed-feed", version: nil, maxRows: nil), context())
            #expect(defaulted.rows.split(separator: "\n").count == GetDatasetTool.defaultFHIRLines)
            #expect(defaulted.truncated)
        }
    }

    // MARK: - update_dataset

    @Test func entriesAndTheExampleDescribeAFHIRDataset() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            _ = try await create(format: "fhirNdjson")
            _ = try await update(entries: [
                .init(resourceType: "Patient", system: nil, code: nil, description: "Arrivals")
            ])
            let out = try await update(
                entries: [
                    .init(resourceType: "Observation", system: "http://loinc.org", code: "8310-5", description: "Oral")
                ],
                example: .init(resourceType: "Patient", id: "p2"))
            let summary = try #require(out.dataset.fhir)
            // Entries by name: the earlier type prose stays.
            #expect(summary.resourceTypes.first { $0.resourceType == "Patient" }?.description == "Arrivals")
            #expect(summary.codes.first { $0.code == "8310-5" }?.description == "Oral")
            #expect(summary.example?.id == "p2")
            try expectValid(out, against: UpdateDatasetTool.outputSchema, "update_dataset")
        }
    }

    @Test func eachFormatRefusesTheOthersDictionary() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            _ = try await create(format: "fhirNdjson")
            _ = try await create(format: nil, url: "https://example.org/wards.csv", body: Self.csv, slug: "wards")
            await #expect(throws: MCPToolError.self) {
                _ = try await self.update(columns: [.init(name: "id", description: "x", unit: nil)])
            }
            await #expect(throws: MCPToolError.self) {
                _ = try await self.update(
                    slug: "wards", entries: [.init(resourceType: "Patient", system: nil, code: nil, description: "x")])
            }
            await #expect(throws: MCPToolError.self) {
                _ = try await self.update(
                    entries: [.init(resourceType: "Encounter", system: nil, code: nil, description: "x")])
            }
        }
    }

    // MARK: - Attachments

    @Test func supportFilesAndTheAssignmentReportTheFormat() async throws {
        try await withApp(app) { _ in
            let assignment = try await fixture()
            _ = try await create(format: "fhirNdjson")
            let attached = try await AttachDatasetTool().execute(
                .init(
                    assignmentPublicID: assignment.publicID, slug: "ed-feed", filename: nil, version: nil,
                    sampleSize: nil, stratumColumn: nil, scope: nil),
                context())
            #expect(attached.dataset.format == "fhirNdjson")
            try expectValid(attached, against: AttachDatasetTool.outputSchema, "attach_dataset")

            let files = try await GetSupportFilesTool().execute(
                .init(assignmentPublicID: assignment.publicID, filename: nil, maxBytes: nil), context())
            #expect(files.files?.first { $0.filename == "ed_feed.ndjson" }?.datasetFormat == "fhirNdjson")

            let got = try await GetAssignmentTool().execute(
                .init(assignmentPublicID: assignment.publicID), context())
            #expect(got.datasets.map(\.format) == ["fhirNdjson"])
        }
    }
}
