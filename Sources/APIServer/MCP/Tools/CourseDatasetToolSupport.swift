// APIServer/MCP/Tools/CourseDatasetToolSupport.swift
//
// What the course dataset library tools share (docs/datasets-course-library.md
// §4.7): the output shapes, their schemas, the dataset lookup and the error
// mapping. The tools are in `CourseDatasetReadTools.swift`,
// `CourseDatasetWriteTools.swift` and `DatasetAttachmentTools.swift`. The work
// is `CourseDatasetService`, which the web Datasets tab and the Files panel
// call too, so the two surfaces refuse the same things with the same words.

import Core
import Fluent
import Foundation
import Vapor

// MARK: - Output shapes

/// One column of a dataset version's dictionary.
struct DatasetColumnDTO: Encodable, Sendable {
    let name: String
    /// The value type inferred from the file (`DatasetColumn.ValueType`).
    let type: String
    let description: String?
    let unit: String?

    init(_ column: DatasetColumn) {
        name = column.name
        type = column.valueType.rawValue
        description = column.description
        unit = column.unit
    }
}

/// One stored version of a dataset.
struct DatasetVersionDTO: Encodable, Sendable {
    let version: Int
    let filename: String
    /// Data rows of a CSV; Patient resources of a FHIR file.
    let rowCount: Int
    let sizeBytes: Int
    let note: String?
    let createdAt: String?

    init(_ version: APICourseDatasetVersion) {
        self.version = version.version
        filename = version.filename
        rowCount = version.rowCount
        sizeBytes = version.sizeBytes
        note = version.note
        createdAt = version.createdAt.map(iso8601String)
    }
}

/// One assignment, or one draft, that attaches a dataset.
struct DatasetUsageDTO: Encodable, Sendable {
    /// Nil for a draft that has no assignment yet.
    let assignmentPublicID: String?
    let assignmentTitle: String?
    /// The attached filename in the assignment.
    let file: String
    /// The pinned version.
    let version: Int
    /// True when the dataset has a newer version than the pinned one.
    let isBehind: Bool
}

/// A library dataset with its versions and the assignments that attach it.
/// `columns` is the newest version's dictionary for a CSV dataset; `fhir` is
/// the newest version's summary and dictionary for a FHIR dataset
/// (docs/fhir-datasets-plan.md §7).
struct DatasetDTO: Encodable, Sendable {
    let slug: String
    let name: String
    /// A `DatasetFormat` raw value: "csv" or "fhirNdjson".
    let format: String
    let description: String?
    let provenance: String?
    let licence: String?
    let isPublished: Bool
    let currentVersion: Int
    let columns: [DatasetColumnDTO]
    let fhir: FHIRDatasetSummary?
    let versions: [DatasetVersionDTO]
    let usage: [DatasetUsageDTO]
}

/// A file of an assignment that comes from the course library.
struct AttachedDatasetDTO: Encodable, Sendable {
    let file: String
    let slug: String
    let version: Int
    /// "course": the same rows in every assignment of the course;
    /// "assignment": rows of this assignment's own.
    let scope: String
    /// Rows per student; nil delivers every row.
    let sampleSize: Int?
    let stratumColumn: String?
    /// The number of parts of a partition; nil for the other kinds.
    let partCount: Int?
    /// A `DatasetFormat` raw value.
    let format: String

    /// Nil for a spec that does not come from the library.
    init?(_ spec: DatasetSpec) {
        guard let source = spec.source else { return nil }
        format = spec.format.rawValue
        file = spec.file
        slug = source.slug
        version = source.version
        scope = spec.scope.rawValue
        sampleSize = spec.sampleSize
        stratumColumn = spec.stratumColumn
        partCount = spec.partCount
    }
}

// MARK: - Schemas

enum DatasetToolSchema {
    static let slug: JSONValue = .object([
        "type": .string("string"),
        "description": .string("The dataset's slug in the course, as list_datasets reports it."),
    ])

    static let scopeValues = DatasetSliceScope.allCases.map(\.rawValue)

    /// One dictionary column. The type enum is derived, so it cannot fall
    /// behind `DatasetColumn.ValueType`.
    static let column: JSONValue = MCPSchema.object(
        properties: [
            "name": MCPSchema.string,
            "type": .object([
                "type": .string("string"),
                "enum": .array(DatasetColumn.ValueType.allCases.map { .string($0.rawValue) }),
            ]),
            "description": MCPSchema.string, "unit": MCPSchema.string,
        ],
        required: ["name", "type"], additionalProperties: nil)

    static let columns: JSONValue = .object(["type": .string("array"), "items": column])

    static let attached: JSONValue = MCPSchema.object(
        properties: [
            "file": MCPSchema.string, "slug": MCPSchema.string, "version": MCPSchema.integer,
            "scope": MCPSchema.string, "sampleSize": MCPSchema.integer, "stratumColumn": MCPSchema.string,
            "partCount": MCPSchema.integer, "format": format,
        ],
        required: ["file", "slug", "version", "scope", "format"], additionalProperties: nil)

    /// A dataset's format. The enum is derived, so it cannot fall behind
    /// `DatasetFormat`.
    static let format: JSONValue = .object([
        "type": .string("string"),
        "enum": .array(DatasetFormat.allCases.map { .string($0.rawValue) }),
    ])

    /// The summary and dictionary of a FHIR version. It mirrors the encoding
    /// of `FHIRDatasetSummary` by hand, so a field added there is added here;
    /// `CourseDatasetFHIRToolsTests` validates real results against it.
    static let fhirSummary: JSONValue = MCPSchema.object(
        properties: [
            "fhirVersion": MCPSchema.string, "resourceCount": MCPSchema.integer, "patientCount": MCPSchema.integer,
            "resourceTypes": .object([
                "type": .string("array"),
                "items": MCPSchema.object(
                    properties: [
                        "resourceType": MCPSchema.string, "count": MCPSchema.integer,
                        "description": MCPSchema.string,
                    ],
                    required: ["resourceType", "count"], additionalProperties: nil),
            ]),
            "codes": .object([
                "type": .string("array"),
                "items": MCPSchema.object(
                    properties: [
                        "resourceType": MCPSchema.string, "system": MCPSchema.string, "code": MCPSchema.string,
                        "display": MCPSchema.string, "count": MCPSchema.integer,
                        "units": .object(["type": .string("array"), "items": MCPSchema.string]),
                        "description": MCPSchema.string,
                    ],
                    required: ["resourceType", "code", "count", "units"], additionalProperties: nil),
            ]),
            "omittedCodeCount": MCPSchema.integer, "danglingPatientReferences": MCPSchema.integer,
            "example": MCPSchema.object(
                properties: ["resourceType": MCPSchema.string, "id": MCPSchema.string, "json": MCPSchema.string],
                required: ["resourceType", "id", "json"], additionalProperties: nil),
        ],
        required: [
            "fhirVersion", "resourceCount", "patientCount", "resourceTypes", "codes", "omittedCodeCount",
            "danglingPatientReferences",
        ],
        additionalProperties: nil)

    static let dataset: JSONValue = MCPSchema.object(
        properties: [
            "slug": MCPSchema.string, "name": MCPSchema.string, "format": format,
            "description": MCPSchema.string,
            "provenance": MCPSchema.string, "licence": MCPSchema.string, "isPublished": MCPSchema.boolean,
            "currentVersion": MCPSchema.integer,
            "columns": columns, "fhir": fhirSummary,
            "versions": .object([
                "type": .string("array"),
                "items": MCPSchema.object(
                    properties: [
                        "version": MCPSchema.integer, "filename": MCPSchema.string, "rowCount": MCPSchema.integer,
                        "sizeBytes": MCPSchema.integer, "note": MCPSchema.string, "createdAt": MCPSchema.string,
                    ],
                    required: ["version", "filename", "rowCount", "sizeBytes"], additionalProperties: nil),
            ]),
            "usage": .object([
                "type": .string("array"),
                "items": MCPSchema.object(
                    properties: [
                        "assignmentPublicID": MCPSchema.string, "assignmentTitle": MCPSchema.string,
                        "file": MCPSchema.string, "version": MCPSchema.integer, "isBehind": MCPSchema.boolean,
                    ],
                    required: ["file", "version", "isBehind"], additionalProperties: nil),
            ]),
        ],
        required: [
            "slug", "name", "format", "isPublished", "currentVersion", "columns", "versions", "usage",
        ],
        additionalProperties: nil)

    /// The `filename` property of a tool that stores a new version.
    static let versionFilename: JSONValue = .object([
        "type": .string("string"),
        "description": .string(
            "The version's filename, a bare name that ends in the dataset format's extension: .csv, or "
                + ".ndjson for FHIR. Required with uploadID. With "
                + "sourceUrl it is optional, and omitted it is the last path segment of the URL."),
    ])

    static let uploadID: JSONValue = .object([
        "type": .string("string"),
        "description": .string(
            "The uploadID from begin_upload, after a UTF-8 file in the dataset's format was PUT to its "
                + "uploadURL. Begun in this course by this agent; needs filename; a successful call uses it up. "
                + "Use it in place of sourceUrl for a file on the agent's own machine."),
    ])

    static let sourceURL: JSONValue = .object([
        "type": .string("string"),
        "description": .string(
            "An https URL of a UTF-8 file in the dataset's format: a CSV with a header row, or FHIR R4 "
                + "NDJSON with one resource per line. The server fetches it under an SSRF guard "
                + "(https only, no private, loopback or metadata hosts, no redirects, "
                + "\(SupportFileURLFetcher.maxBytesText) cap)."),
    ])
}

// MARK: - Where a new version's bytes come from

/// The source of a new library version: a `sourceUrl` the server fetches, or a
/// staged `begin_upload` upload (docs/mcp-file-uploads.md).
enum DatasetVersionSource {
    case url(String)
    case upload(id: String)

    /// The one source given, or nil when neither or both are.
    init?(sourceUrl: String?, uploadID: String?) {
        let url = (sourceUrl?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let upload = (uploadID?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        switch (url, upload) {
        case (let url?, nil): self = .url(url)
        case (nil, let upload?): self = .upload(id: upload)
        default: return nil
        }
    }

    /// The version to store, and the staged upload to consume once the store
    /// succeeds (nil for a URL). An upload must be in `courseID` and needs a
    /// `filename`, since it has no URL to name it.
    func materialize(
        filename: String?, note: String?, courseID: UUID, fetch: DatasetSourceFetch, context: ToolContext
    ) async throws -> (upload: CourseDatasetService.Upload, staged: MCPUploadService.Staged?) {
        switch self {
        case .url(let url):
            let bytes = try await fetch(url, context.request)
            return (.init(filename: datasetVersionFilename(filename, sourceURL: url), bytes: bytes, note: note), nil)
        case .upload(let id):
            guard let filename = filename?.trimmingCharacters(in: .whitespaces), !filename.isEmpty else {
                throw MCPToolError.invalidArguments(
                    detail:
                        "Pass filename with uploadID: the stored filename, a bare name that ends in .csv, or .ndjson for FHIR."
                )
            }
            let staged = try await loadMCPUpload(id, courseID: courseID, context: context)
            return (.init(filename: filename, bytes: staged.bytes, note: note), staged)
        }
    }
}

// MARK: - Lookups and errors

/// Fetches the bytes of a `sourceUrl`. The tools take it as a property, so a
/// test can give the bytes without a network.
typealias DatasetSourceFetch = @Sendable (_ url: String, _ request: Request) async throws -> Data

/// The production fetch, under the SSRF guard.
let fetchDatasetSource: DatasetSourceFetch = { url, request in
    do {
        return try await SupportFileURLFetcher.fetchData(urlString: url, on: request)
    } catch let error as SupportFileFetchError {
        throw MCPToolError.invalidArguments(detail: error.toolDetail)
    }
}

/// Runs a library operation and gives a refusal to the agent in the words the
/// web panel uses.
func datasetLibraryCall<T>(_ operation: () async throws -> T) async throws -> T {
    do {
        return try await operation()
    } catch let error as CourseDatasetError {
        throw MCPToolError.invalidArguments(detail: error.description)
    }
}

/// The dataset `slug` of `courseID`, or a refusal that names the slug.
func requireCourseDataset(slug: String, courseID: UUID, context: ToolContext) async throws -> APICourseDataset {
    guard let dataset = try await CourseDatasetService.find(courseID: courseID, slug: slug, on: context.db) else {
        throw MCPToolError.invalidArguments(
            detail: "No dataset with the slug \"\(slug)\" in this course. list_datasets lists them.")
    }
    return dataset
}

/// The full output shape of `dataset`: its versions, the newest dictionary and
/// the assignments that attach it.
func datasetDTO(_ dataset: APICourseDataset, context: ToolContext) async throws -> DatasetDTO {
    datasetDTO(
        dataset,
        versions: try await CourseDatasetService.versions(of: dataset, on: context.db),
        usage: try await CourseDatasetService.usage(of: dataset, on: context.db))
}

/// `datasetDTO` from the dataset's versions (oldest first) and its usage,
/// already read, for a list of datasets that reads them in batch. A list
/// leaves out the FHIR summary (`includingSummary: false`): it can list 500
/// codes and a 16 KB example per dataset, and `get_dataset` returns it.
func datasetDTO(
    _ dataset: APICourseDataset, versions: [APICourseDatasetVersion], usage: [CourseDatasetService.Usage],
    includingSummary: Bool = true
) -> DatasetDTO {
    let newest = versions.first { $0.version == dataset.currentVersion }
    return DatasetDTO(
        slug: dataset.slug, name: dataset.name, format: dataset.format.rawValue,
        description: dataset.datasetDescription,
        provenance: dataset.provenance, licence: dataset.licence, isPublished: dataset.isPublished,
        currentVersion: dataset.currentVersion, columns: (newest?.columns ?? []).map(DatasetColumnDTO.init),
        fhir: includingSummary ? newest?.summary : nil,
        versions: versions.map(DatasetVersionDTO.init),
        // `Usage` carries the pinned version and not the spec, so this is
        // `CourseDatasetService.attachmentIsBehind` on the version alone.
        usage: usage.map {
            DatasetUsageDTO(
                assignmentPublicID: $0.assignmentPublicID, assignmentTitle: $0.assignmentTitle, file: $0.file,
                version: $0.version, isBehind: $0.version < dataset.currentVersion)
        })
}

/// The stored filename for a version fetched from `sourceUrl`: `filename`
/// when given, else the URL's last path segment.
func datasetVersionFilename(_ filename: String?, sourceURL: String) -> String {
    if let filename, !filename.trimmingCharacters(in: .whitespaces).isEmpty { return filename }
    return attachmentFilename(fromURL: sourceURL)
}

/// The slug for a new dataset: `slug` when given, else one made from `name`.
func newDatasetSlug(_ slug: String?, name: String) throws -> String {
    if let slug { return slug }
    let suggested = CourseDatasetService.suggestedSlug(from: name)
    guard !suggested.isEmpty else {
        throw MCPToolError.invalidArguments(
            detail: "The name \"\(name)\" has no letter or digit to make a slug from. Pass slug.")
    }
    return suggested
}
