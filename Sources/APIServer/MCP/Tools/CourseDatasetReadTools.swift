// APIServer/MCP/Tools/CourseDatasetReadTools.swift
//
// Read tools for the course dataset library (docs/datasets-course-library.md
// §4.7): `list_datasets` and `get_dataset`. content:read, course-scoped. A
// dataset is instructor-authored content, the same trust tier as a support
// file; the pool rows that `get_dataset` shows are the file the instructor
// uploaded, not any student's data.

import Core
import Fluent
import Foundation
import Vapor

// MARK: - list_datasets

struct ListDatasetsTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseCode: String
    }

    struct Output: Encodable, Sendable {
        let courseCode: String
        let courseKey: String
        let courseTerm: String?
        /// By name.
        let datasets: [DatasetDTO]
    }

    static let name = "list_datasets"
    static let description =
        "List the course's dataset library: every dataset with its slug, name, provenance, licence, "
        + "whether students see it on the course Data page (isPublished), its versions, the newest "
        + "version's data dictionary, and the assignments that attach it with the version each one pins "
        + "(isBehind is true when a newer version exists). A library dataset is a file kept once per course "
        + "and copied into each assignment that attaches it. Its format is csv, with a column dictionary "
        + "in columns, or fhirNdjson, FHIR R4 resources one per line, whose summary (patients, resource "
        + "types, codes in use, the instructor's descriptions and the example resource) get_dataset "
        + "returns as fhir; a FHIR version's rowCount counts patients."
    static let inputSchema: JSONValue = MCPSchema.object(
        properties: ["courseCode": MCPSchema.courseCode], required: ["courseCode"])
    static let outputSchema: JSONValue? = MCPSchema.object(
        properties: [
            "courseCode": MCPSchema.string, "courseKey": MCPSchema.courseKeyOutput,
            "courseTerm": MCPSchema.courseTermOutput,
            "datasets": .object(["type": .string("array"), "items": DatasetToolSchema.dataset]),
        ],
        required: ["courseCode", "courseKey", "datasets"], additionalProperties: nil)
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let course = try await resolveCourse(code: input.courseCode, context: context)
        let courseID = try course.requireID()
        let library = try await CourseDatasetService.list(courseID: courseID, on: context.db)
        // The versions and the usage of every dataset in one read each, not
        // one per dataset: usage reads every manifest of the course.
        var datasets: [DatasetDTO] = []
        if !library.isEmpty {
            let versionsByDataset = try await CourseDatasetService.versionsByDataset(library, on: context.db)
            let usageBySlug = try await CourseDatasetService.usageBySlug(courseID: courseID, on: context.db)
            datasets = try library.map { dataset in
                datasetDTO(
                    dataset, versions: versionsByDataset[try dataset.requireID()] ?? [],
                    usage: usageBySlug[dataset.slug] ?? [], includingSummary: false)
            }
        }
        return Output(
            courseCode: course.code, courseKey: course.urlKey, courseTerm: course.term?.displayName,
            datasets: datasets)
    }
}

// MARK: - get_dataset

struct GetDatasetTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseCode: String
        let slug: String
        /// The version whose rows and dictionary to read. Nil means the newest.
        let version: Int?
        let maxRows: Int?
    }

    struct Output: Encodable, Sendable {
        let courseCode: String
        let courseKey: String
        let courseTerm: String?
        let dataset: DatasetDTO
        /// The version that `rows` and `columns` are of.
        let version: Int
        /// That version's dictionary. `dataset.columns` is the newest one's.
        let columns: [DatasetColumnDTO]
        /// The header and the first data rows of that version, as CSV text,
        /// or the first resource lines of a FHIR version, at most
        /// `MCPContentByteCap.defaultBytes` bytes.
        let rows: String
        let rowCount: Int
        /// True when `rows` holds fewer data rows than the version has.
        let truncated: Bool
    }

    static let rowLimit = MCPBoundedInt(default: 10, max: 200)
    /// The default number of FHIR resource lines. A line is a whole
    /// resource, so fewer are shown; `rowLimit` still bounds an explicit
    /// `maxRows`.
    static let defaultFHIRLines = 5

    static let name = "get_dataset"
    static let description =
        "Get one dataset of the course library by slug: its metadata, versions and usage (as "
        + "list_datasets reports them), plus the header and the first rows of one version as CSV text "
        + "and that version's data dictionary, capped at \(MCPContentByteCap.defaultBytes) bytes. These are "
        + "the rows of the uploaded file. A student "
        + "receives a sample of them, or all of them, as the assignment that attaches the file says; "
        + "preview_personalization shows one student's rows. For a FHIR dataset, rows holds the first "
        + "maxRows resource lines (default 5) and dataset.fhir the newest version's summary; every "
        + "student receives the whole file."
    static let inputSchema: JSONValue = MCPSchema.object(
        properties: [
            "courseCode": MCPSchema.courseCode, "slug": DatasetToolSchema.slug,
            "version": .object([
                "type": .string("integer"), "minimum": .int(1),
                "description": .string("Optional. The version to read. Omitted, the newest."),
            ]),
            "maxRows": rowLimit.property(
                "Data rows to return. For FHIR, resource lines, \(defaultFHIRLines) when omitted; for a CSV,"),
        ],
        required: ["courseCode", "slug"])
    static let outputSchema: JSONValue? = MCPSchema.object(
        properties: [
            "courseCode": MCPSchema.string, "courseKey": MCPSchema.courseKeyOutput,
            "courseTerm": MCPSchema.courseTermOutput, "dataset": DatasetToolSchema.dataset,
            "version": MCPSchema.integer, "columns": DatasetToolSchema.columns, "rows": MCPSchema.string,
            "rowCount": MCPSchema.integer, "truncated": MCPSchema.boolean,
        ],
        required: ["courseCode", "courseKey", "dataset", "version", "columns", "rows", "rowCount", "truncated"],
        additionalProperties: nil)
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let course = try await resolveCourse(code: input.courseCode, context: context)
        let dataset = try await requireCourseDataset(
            slug: input.slug, courseID: try course.requireID(), context: context)
        let number = input.version ?? dataset.currentVersion
        guard let version = try await CourseDatasetService.version(number, of: dataset, on: context.db) else {
            throw MCPToolError.invalidArguments(detail: CourseDatasetError.unknownVersion(number).description)
        }
        let blobs = AssignmentVersionBlobStore(testSetupsDirectory: context.request.application.testSetupsDirectory)
        // A version is checked as UTF-8 when it is stored, so a nil here is a
        // blob that cannot be read.
        guard let bytes = try? CourseDatasetService.bytes(of: version, blobs: blobs),
            let text = String(bytes: bytes, encoding: .utf8)
        else {
            throw MCPToolError.executionFailed(detail: "The bytes of version \(number) could not be read.")
        }
        // One row per line, as the materializer that samples the rows reads
        // them. A CSV shows its header and `limit` rows; a FHIR file, which
        // has no header, `limit` resource lines. A FHIR version's `rowCount`
        // counts patients, not lines, so whether lines were left out is read
        // from the lines themselves.
        let lines = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
        let shown: Int
        let linesLeftOut: Bool
        switch dataset.format {
        case .csv:
            let limit = Self.rowLimit.resolve(input.maxRows)
            shown = limit + 1
            linesLeftOut = version.rowCount > limit
        case .fhirNdjson:
            shown = input.maxRows.map { Self.rowLimit.resolve($0) } ?? Self.defaultFHIRLines
            linesLeftOut = lines.count > shown
        }
        let head = lines.prefix(shown).joined(separator: "\n") + "\n"
        let capped = MCPContentByteCap.cappedUTF8(Data(head.utf8), cap: MCPContentByteCap.defaultBytes)
        return Output(
            courseCode: course.code, courseKey: course.urlKey, courseTerm: course.term?.displayName,
            dataset: try await datasetDTO(dataset, context: context), version: number,
            columns: version.columns.map(DatasetColumnDTO.init), rows: capped?.content ?? head,
            rowCount: version.rowCount, truncated: linesLeftOut || capped?.truncated == true)
    }
}
