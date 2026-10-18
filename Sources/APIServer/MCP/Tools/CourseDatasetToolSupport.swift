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
/// `columns` is the newest version's dictionary.
struct DatasetDTO: Encodable, Sendable {
    let slug: String
    let name: String
    let description: String?
    let provenance: String?
    let licence: String?
    let isPublished: Bool
    let currentVersion: Int
    let columns: [DatasetColumnDTO]
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

    /// Nil for a spec that does not come from the library.
    init?(_ spec: DatasetSpec) {
        guard let source = spec.source else { return nil }
        file = spec.file
        slug = source.slug
        version = source.version
        scope = spec.scope.rawValue
        sampleSize = spec.sampleSize
        stratumColumn = spec.stratumColumn
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
        ],
        required: ["file", "slug", "version", "scope"], additionalProperties: nil)

    static let dataset: JSONValue = MCPSchema.object(
        properties: [
            "slug": MCPSchema.string, "name": MCPSchema.string, "description": MCPSchema.string,
            "provenance": MCPSchema.string, "licence": MCPSchema.string, "isPublished": MCPSchema.boolean,
            "currentVersion": MCPSchema.integer,
            "columns": columns,
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
            "slug", "name", "isPublished", "currentVersion", "columns", "versions", "usage",
        ],
        additionalProperties: nil)

    /// The `filename` property of a tool that stores a new version.
    static let versionFilename: JSONValue = .object([
        "type": .string("string"),
        "description": .string(
            "Optional. The version's filename, a bare name that ends in .csv. Omitted, it is the last "
                + "path segment of sourceUrl."),
    ])

    static let sourceURL: JSONValue = .object([
        "type": .string("string"),
        "description": .string(
            "An https URL of a UTF-8 CSV file with a header row. The server fetches it under an SSRF guard "
                + "(https only, no private, loopback or metadata hosts, no redirects, "
                + "\(SupportFileURLFetcher.maxBytesText) cap)."),
    ])
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
    let versions = try await CourseDatasetService.versions(of: dataset, on: context.db)
    let usage = try await CourseDatasetService.usage(of: dataset, on: context.db)
    let newest = versions.first { $0.version == dataset.currentVersion }
    return DatasetDTO(
        slug: dataset.slug, name: dataset.name, description: dataset.datasetDescription,
        provenance: dataset.provenance, licence: dataset.licence, isPublished: dataset.isPublished,
        currentVersion: dataset.currentVersion, columns: (newest?.columns ?? []).map(DatasetColumnDTO.init),
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
