// APIServer/MCP/Tools/CourseDatasetWriteTools.swift
//
// Write tools for the course dataset library itself
// (docs/datasets-course-library.md §4.7): `create_dataset`, `update_dataset`
// and `add_dataset_version`. content:write, TA and above, as the web Datasets
// tab.
//
// None of them changes what an assignment grades. A new version changes no
// attached file, because an attachment pins its version; `attach_dataset`
// moves an assignment to it. A create that promotes a support file records
// where the file came from and keeps its bytes, sample and scope, so every
// student keeps the rows they had (the web promote does not re-grade either).

import Core
import Fluent
import Foundation
import Vapor

// MARK: - create_dataset

struct CreateDatasetTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseCode: String
        let name: String
        /// Nil makes one from the name.
        let slug: String?
        let description: String?
        let provenance: String?
        let licence: String?
        /// Version 1 from a URL ...
        let sourceUrl: String?
        let note: String?
        /// ... or from this assignment's support file `filename`.
        let assignmentPublicID: String?
        /// With `sourceUrl`, the stored filename; with `assignmentPublicID`, the
        /// support file to move into the library.
        let filename: String?
    }

    struct Output: Encodable, Sendable {
        let courseKey: String
        let dataset: DatasetDTO
    }

    var fetch: DatasetSourceFetch = fetchDatasetSource

    static let name = "create_dataset"
    static let description =
        "Create a dataset in the course library. Version 1 comes from ONE of two places: a CSV at "
        + "sourceUrl, or a support file of an assignment (assignmentPublicID plus filename). From an "
        + "assignment, the file becomes attached to the new dataset and keeps its bytes, its sample and "
        + "its scope, so no student's rows change. The dataset starts unpublished: students see it on the "
        + "course Data page only after update_dataset publishes it, which needs a provenance and a licence. "
        + "The dictionary's value types are inferred from the file; describe the columns with "
        + "update_dataset. Attach the dataset to an assignment with attach_dataset."
    static let inputSchema: JSONValue = MCPSchema.object(
        properties: [
            "courseCode": MCPSchema.courseCode,
            "name": .object(["type": .string("string"), "description": .string("The name students see.")]),
            "slug": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional. 1 to 64 lowercase letters, digits and hyphens, unique in the course. Omitted, "
                        + "it is made from the name."),
            ]),
            "description": .object(["type": .string("string"), "description": .string("Optional.")]),
            "provenance": .object([
                "type": .string("string"),
                "description": .string("Optional. Where the data came from. Publishing needs it."),
            ]),
            "licence": .object([
                "type": .string("string"),
                "description": .string("Optional. The terms of use. Publishing needs it."),
            ]),
            "sourceUrl": DatasetToolSchema.sourceURL,
            "note": .object([
                "type": .string("string"), "description": .string("Optional. A note on version 1."),
            ]),
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string(
                    "Instead of sourceUrl: the assignment whose support file becomes version 1. It must be in "
                        + "the same course."),
            ]),
            "filename": .object([
                "type": .string("string"),
                "description": .string(
                    "With sourceUrl: optional, the stored filename (default: the URL's last path segment). "
                        + "With assignmentPublicID: required, the support file to move into the library."),
            ]),
        ],
        required: ["courseCode", "name"])
    static let outputSchema: JSONValue? = MCPSchema.object(
        properties: ["courseKey": MCPSchema.courseKeyOutput, "dataset": DatasetToolSchema.dataset],
        required: ["courseKey", "dataset"], additionalProperties: nil)
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: false)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let course = try await resolveCourseForWrite(code: input.courseCode, context: context, atLeast: .ta)
        let courseID = try course.requireID()
        let testSetupsDirectory = context.request.application.testSetupsDirectory
        let new = CourseDatasetService.NewDataset(
            name: input.name, slug: input.slug ?? CourseDatasetService.suggestedSlug(from: input.name),
            description: input.description, provenance: input.provenance, licence: input.licence)

        let dataset: APICourseDataset
        switch (input.sourceUrl, input.assignmentPublicID) {
        case (let url?, nil):
            let bytes = try await fetch(url, context.request)
            let upload = CourseDatasetService.Upload(
                filename: datasetVersionFilename(input.filename, sourceURL: url), bytes: bytes, note: input.note)
            dataset = try await datasetLibraryCall {
                try await CourseDatasetService.create(
                    courseID: courseID, dataset: new, upload: upload,
                    blobs: AssignmentVersionBlobStore(testSetupsDirectory: testSetupsDirectory), on: context.db
                ).dataset
            }
        case (nil, let publicID?):
            guard let filename = input.filename else {
                throw MCPToolError.invalidArguments(
                    detail: "Pass filename: the support file of the assignment to move into the library.")
            }
            let (_, setup) = try await context.authorizedAssignmentAndSetupForWrite(publicID: publicID, atLeast: .ta)
            guard setup.courseID == courseID else {
                throw MCPToolError.invalidArguments(
                    detail: "The assignment \(publicID) is not in \(course.urlKey). A dataset belongs to one course.")
            }
            dataset = try await datasetLibraryCall {
                try await CourseDatasetService.promote(
                    file: filename, from: setup, dataset: new, testSetupsDirectory: testSetupsDirectory,
                    on: context.db
                ).dataset
            }
        default:
            throw MCPToolError.invalidArguments(
                detail: "Pass exactly one of sourceUrl or assignmentPublicID as the source of version 1.")
        }
        return Output(courseKey: course.urlKey, dataset: try await datasetDTO(dataset, context: context))
    }
}

// MARK: - update_dataset

struct UpdateDatasetTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseCode: String
        let slug: String
        let name: String?
        let description: String?
        let provenance: String?
        let licence: String?
        let isPublished: Bool?
        /// The prose of the newest version's columns. A column it does not
        /// name keeps its prose.
        let columns: [ColumnInput]?
    }

    struct ColumnInput: Decodable, Sendable {
        let name: String
        let description: String?
        let unit: String?
    }

    struct Output: Encodable, Sendable {
        let courseKey: String
        let dataset: DatasetDTO
    }

    static let name = "update_dataset"
    static let description =
        "Change a library dataset: its name, description, provenance and licence, whether students see "
        + "it on the course Data page (isPublished), and the descriptions and units of the newest "
        + "version's columns. An omitted field is left as it is; an empty string clears a text field. "
        + "columns changes only the columns it names: send {name, description, unit} per column, with "
        + "\"\" to clear one. A column's value type is inferred from the file and cannot be set. "
        + "Publishing needs a provenance and a licence, and a published dataset must keep both. No "
        + "assignment's grades change."
    static let inputSchema: JSONValue = MCPSchema.object(
        properties: [
            "courseCode": MCPSchema.courseCode, "slug": DatasetToolSchema.slug,
            "name": MCPSchema.string, "description": MCPSchema.string, "provenance": MCPSchema.string,
            "licence": MCPSchema.string,
            "isPublished": .object([
                "type": .string("boolean"),
                "description": .string("True shows the dataset to students on the course Data page."),
            ]),
            "columns": .object([
                "type": .string("array"),
                "description": .string("Optional. Prose for the named columns of the newest version."),
                "items": MCPSchema.object(
                    properties: [
                        "name": MCPSchema.string, "description": MCPSchema.string, "unit": MCPSchema.string,
                    ],
                    required: ["name"]),
            ]),
        ],
        required: ["courseCode", "slug"])
    static let outputSchema: JSONValue? = MCPSchema.object(
        properties: ["courseKey": MCPSchema.courseKeyOutput, "dataset": DatasetToolSchema.dataset],
        required: ["courseKey", "dataset"], additionalProperties: nil)
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let course = try await resolveCourseForWrite(code: input.courseCode, context: context, atLeast: .ta)
        let dataset = try await requireCourseDataset(
            slug: input.slug, courseID: try course.requireID(), context: context)
        try await datasetLibraryCall {
            // Unpublish first and publish last, so one call can clear the
            // licence of a published dataset, or fill it and publish.
            if input.isPublished == false {
                try await CourseDatasetService.setPublished(dataset, false, on: context.db)
            }
            try await CourseDatasetService.updateMetadata(
                dataset,
                edit: .init(
                    name: input.name, description: input.description, provenance: input.provenance,
                    licence: input.licence),
                on: context.db)
            if let columns = input.columns {
                try await updateColumns(columns, of: dataset, context: context)
            }
            if input.isPublished == true {
                try await CourseDatasetService.setPublished(dataset, true, on: context.db)
            }
        }
        return Output(courseKey: course.urlKey, dataset: try await datasetDTO(dataset, context: context))
    }

    /// Merges `columns` into the newest version's prose. The service replaces
    /// the prose of every column, so the columns that `columns` does not name
    /// are sent with the prose they have.
    private func updateColumns(
        _ columns: [ColumnInput], of dataset: APICourseDataset, context: ToolContext
    ) async throws {
        guard let newest = try await CourseDatasetService.version(dataset.currentVersion, of: dataset, on: context.db)
        else { throw CourseDatasetError.unknownVersion(dataset.currentVersion) }
        let named = Dictionary(columns.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        var notes = newest.columns.map { column in
            let edit = named[column.name]
            return CourseDatasetService.ColumnNote(
                name: column.name, description: edit?.description ?? column.description,
                unit: edit?.unit ?? column.unit)
        }
        // A name the file lacks goes through, so the service refuses it by name.
        let header = Set(newest.columns.map(\.name))
        notes += columns.filter { !header.contains($0.name) }.map {
            CourseDatasetService.ColumnNote(name: $0.name, description: $0.description, unit: $0.unit)
        }
        _ = try await CourseDatasetService.updateDictionary(
            dataset, version: dataset.currentVersion, notes: notes, on: context.db)
    }
}

// MARK: - add_dataset_version

struct AddDatasetVersionTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseCode: String
        let slug: String
        let sourceUrl: String
        let filename: String?
        let note: String?
    }

    struct Output: Encodable, Sendable {
        let courseKey: String
        /// The number of the new version.
        let version: Int
        /// Columns of the previous version that the new file lacks. Their
        /// prose was dropped.
        let droppedColumns: [String]
        let dataset: DatasetDTO
    }

    var fetch: DatasetSourceFetch = fetchDatasetSource

    static let name = "add_dataset_version"
    static let description =
        "Add a new version to a library dataset from a CSV at sourceUrl, with an optional note. The "
        + "dictionary prose carries over by column name, and droppedColumns names the columns the new "
        + "file lacks. Bytes equal to an earlier version are refused. Attached assignments keep the "
        + "version they pin, so no grade changes: the result's usage marks each one isBehind, and "
        + "attach_dataset moves an assignment to the new version."
    static let inputSchema: JSONValue = MCPSchema.object(
        properties: [
            "courseCode": MCPSchema.courseCode, "slug": DatasetToolSchema.slug,
            "sourceUrl": DatasetToolSchema.sourceURL, "filename": DatasetToolSchema.versionFilename,
            "note": .object([
                "type": .string("string"), "description": .string("Optional. What changed in this version."),
            ]),
        ],
        required: ["courseCode", "slug", "sourceUrl"])
    static let outputSchema: JSONValue? = MCPSchema.object(
        properties: [
            "courseKey": MCPSchema.courseKeyOutput, "version": MCPSchema.integer,
            "droppedColumns": .object(["type": .string("array"), "items": MCPSchema.string]),
            "dataset": DatasetToolSchema.dataset,
        ],
        required: ["courseKey", "version", "droppedColumns", "dataset"], additionalProperties: nil)
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: false)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let course = try await resolveCourseForWrite(code: input.courseCode, context: context, atLeast: .ta)
        let dataset = try await requireCourseDataset(
            slug: input.slug, courseID: try course.requireID(), context: context)
        let bytes = try await fetch(input.sourceUrl, context.request)
        let upload = CourseDatasetService.Upload(
            filename: datasetVersionFilename(input.filename, sourceURL: input.sourceUrl), bytes: bytes,
            note: input.note)
        let added = try await datasetLibraryCall {
            try await CourseDatasetService.addVersion(
                to: dataset, upload: upload,
                blobs: AssignmentVersionBlobStore(testSetupsDirectory: context.request.application.testSetupsDirectory),
                on: context.db)
        }
        return Output(
            courseKey: course.urlKey, version: added.version.version, droppedColumns: added.droppedColumns,
            dataset: try await datasetDTO(dataset, context: context))
    }
}
