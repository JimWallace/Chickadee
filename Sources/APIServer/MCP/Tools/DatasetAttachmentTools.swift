// APIServer/MCP/Tools/DatasetAttachmentTools.swift
//
// Write tools that attach a course library dataset to an assignment and
// detach it (docs/datasets-course-library.md §4.7): `attach_dataset` and
// `detach_dataset`. content:write, TA and above, as the Files panel.
//
// They mirror the web library routes (`PublishedAssignmentRoutes+DatasetLibrary`):
// an attach, a move to another version, a scope change and a detach change the
// rows each student receives, so each one re-grades and re-validates
// (`applyContentEditEffects`). Like those routes, and like `set_dataset`, none
// of them closes the assignment: the suite is unchanged.
//
// The library fields of a spec (its source and its scope) are written only
// here, never by `set_dataset` (`DatasetSpecValidation.libraryFieldIssue`). So
// the scope of a file that is already attached changes through
// `attach_dataset`, and the sample through `set_dataset`.

import Core
import Fluent
import Foundation
import Vapor

// MARK: - attach_dataset

struct AttachDatasetTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        let slug: String
        /// The filename in the assignment. Nil means the version's filename,
        /// or the one file already attached from this dataset.
        let filename: String?
        /// Nil means the newest.
        let version: Int?
        let sampleSize: Int?
        let stratumColumn: String?
        /// "course" or "assignment". Nil means "course" for a new attachment
        /// and "leave it" for an attached file.
        let scope: String?
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        /// "attached", "updated" or "unchanged".
        let action: String
        let dataset: AttachedDatasetDTO
        /// Submissions re-queued to re-grade with the new rows.
        let submissionsRequeued: Int
    }

    static let name = "attach_dataset"
    static let description =
        "Attach a course library dataset to an assignment by slug, as a support file. The server copies "
        + "the version's bytes into the assignment and pins that version, so a new library version changes "
        + "nothing until you call this again. Pass sampleSize for a per-student row sample (and "
        + "stratumColumn to balance it across a column), or omit it to give every student every row. scope "
        + "\"course\" (the default) gives a student the same rows in every assignment of the course that "
        + "attaches the dataset, so later work builds on the same cohort; \"assignment\" gives rows of this "
        + "assignment's own. Called on a file that is already attached from the dataset, it moves the file "
        + "to the version asked for (the newest by default) and sets scope when given; the sample stays, "
        + "and set_dataset changes it. A change re-grades the assignment's submissions and re-validates; it "
        + "does not close the assignment. detach_dataset ends an attachment. "
        + MCPActivityProse.sharedDataRule
    static let inputSchema: JSONValue = MCPSchema.object(
        properties: [
            "assignmentPublicID": MCPSchema.assignmentPublicID, "slug": DatasetToolSchema.slug,
            "filename": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional. The filename in the assignment, a bare name that ends in .csv. Omitted, the "
                        + "version's own filename, or the file already attached from this dataset. A name that "
                        + "no attached file has makes another attachment of the dataset; it does not rename one."),
            ]),
            "version": .object([
                "type": .string("integer"), "minimum": .int(1),
                "description": .string("Optional. The version to pin. Omitted, the newest."),
            ]),
            "sampleSize": .object([
                "type": .string("integer"), "minimum": .int(1),
                "description": .string("Optional, new attachment only. Data rows each student receives."),
            ]),
            "stratumColumn": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional, new attachment only. A header column to balance the sample across."),
            ]),
            "scope": .object([
                "type": .string("string"), "enum": .array(DatasetToolSchema.scopeValues.map { .string($0) }),
                "description": .string("Optional. Whose seed picks a student's rows; see the description."),
            ]),
        ],
        required: ["assignmentPublicID", "slug"])
    static let outputSchema: JSONValue? = MCPSchema.object(
        properties: [
            "assignmentPublicID": MCPSchema.string, "action": MCPSchema.string,
            "dataset": DatasetToolSchema.attached, "submissionsRequeued": MCPSchema.integer,
        ],
        required: ["assignmentPublicID", "action", "dataset", "submissionsRequeued"], additionalProperties: nil)
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, atLeast: .ta)
        let dataset = try await requireCourseDataset(slug: input.slug, courseID: setup.courseID, context: context)
        let scope = try input.scope.map(Self.scope(from:))
        let attached = (setup.decodedManifest()?.datasets ?? []).filter {
            $0.source?.slug == dataset.slug && (input.filename == nil || $0.file == input.filename)
        }
        let testSetupsDirectory = context.request.application.testSetupsDirectory

        let action: String
        let spec: DatasetSpec
        if let existing = attached.first, attached.count == 1, let source = existing.source {
            guard input.sampleSize == nil, input.stratumColumn == nil else {
                throw MCPToolError.invalidArguments(
                    detail: "'\(existing.file)' is already attached from \(dataset.slug). Change its sample "
                        + "with set_dataset.")
            }
            var current = existing
            try await datasetLibraryCall {
                if (input.version ?? dataset.currentVersion) != source.version {
                    current = try await CourseDatasetService.updateAttachment(
                        file: existing.file, in: setup, to: input.version,
                        testSetupsDirectory: testSetupsDirectory, on: context.db)
                }
                if let scope, scope != current.scope {
                    current = try await CourseDatasetService.setAttachmentScope(
                        file: existing.file, in: setup, to: scope, on: context.db)
                }
            }
            action = current == existing ? "unchanged" : "updated"
            spec = current
        } else if attached.count > 1 {
            throw MCPToolError.invalidArguments(
                detail: "\(dataset.slug) is attached as \(attached.map(\.file).joined(separator: ", ")). Pass "
                    + "filename to say which.")
        } else {
            spec = try await datasetLibraryCall {
                try await CourseDatasetService.attach(
                    dataset, to: setup,
                    request: .init(
                        version: input.version, filename: input.filename, sampleSize: input.sampleSize,
                        stratumColumn: input.stratumColumn, scope: scope ?? .course),
                    testSetupsDirectory: testSetupsDirectory, on: context.db)
            }
            action = "attached"
        }

        var requeued = 0
        if action != "unchanged" {
            requeued = await applyContentEditEffects(
                .gradeAffecting, assignment: assignment, setup: setup,
                actingUserID: try? await context.requireEligibleSubject().id, context: context.request)
        }
        guard let dto = AttachedDatasetDTO(spec) else {
            throw MCPToolError.executionFailed(detail: "The attached spec has no library source.")
        }
        return Output(
            assignmentPublicID: assignment.publicID, action: action, dataset: dto, submissionsRequeued: requeued)
    }

    private static func scope(from raw: String) throws -> DatasetSliceScope {
        guard let scope = DatasetSliceScope(rawValue: raw) else {
            throw MCPToolError.invalidArguments(
                detail: "scope must be one of \(DatasetToolSchema.scopeValues.joined(separator: ", ")).")
        }
        return scope
    }
}

// MARK: - detach_dataset

struct DetachDatasetTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        let filename: String
        let removeFile: Bool?
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let file: String
        let removedFile: Bool
        /// Submissions re-queued to re-grade with the new rows.
        let submissionsRequeued: Int
    }

    static let name = "detach_dataset"
    static let description =
        "End the library attachment of an assignment's file. By default the file stays as an ordinary "
        + "support file and keeps its sample, so every student still receives a sample rather than the "
        + "whole file; a course-scope sample goes back to this assignment's own rows. removeFile:true "
        + "deletes the file too, which is refused while a test depends on it. Re-grades the assignment's "
        + "submissions and re-validates; it does not close the assignment."
    static let inputSchema: JSONValue = MCPSchema.object(
        properties: [
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "filename": .object([
                "type": .string("string"),
                "description": .string("The attached file, as get_support_files lists it."),
            ]),
            "removeFile": .object([
                "type": .string("boolean"), "description": .string("True to delete the file too."),
            ]),
        ],
        required: ["assignmentPublicID", "filename"])
    static let outputSchema: JSONValue? = MCPSchema.object(
        properties: [
            "assignmentPublicID": MCPSchema.string, "file": MCPSchema.string, "removedFile": MCPSchema.boolean,
            "submissionsRequeued": MCPSchema.integer,
        ],
        required: ["assignmentPublicID", "file", "removedFile", "submissionsRequeued"], additionalProperties: nil)
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: true, idempotentHint: false)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, atLeast: .ta)
        let removeFile = input.removeFile ?? false
        try await datasetLibraryCall {
            try await CourseDatasetService.detach(
                file: input.filename, from: setup, removeFile: removeFile,
                testSetupsDirectory: context.request.application.testSetupsDirectory, on: context.db)
        }
        let requeued = await applyContentEditEffects(
            .gradeAffecting, assignment: assignment, setup: setup,
            actingUserID: try? await context.requireEligibleSubject().id, context: context.request)
        return Output(
            assignmentPublicID: assignment.publicID, file: input.filename, removedFile: removeFile,
            submissionsRequeued: requeued)
    }
}
