// APIServer/MCP/Tools/SetDatasetTool.swift
//
// Write tool: mark a bundled support file as a per-student dataset (Phase 1 of
// docs/datasets.md), or clear the mark, by assignment public ID.
// content:write, course-scoped.
//
// A dataset spec turns "one CSV every student shares" into "each student gets
// a deterministic per-seed row sample under the same filename": the notebook's
// `pd.read_csv("…")` line is unchanged, but every student sees their own rows
// in the editor, in browser grading, and on the worker. The spec lives in the
// test setup's manifest (`TestProperties.datasets`) and mirrors the web
// `PUT /instructor/:id/datasets` endpoint's validation; like that endpoint —
// and like set_grading_mode — changing it does not close the assignment or
// re-run validation, because the suite's checks are unchanged. Existing
// submissions pick up the new slice on their next (re)grade.

import Core
import Fluent
import Foundation

struct SetDatasetTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// A bundled support filename (bare name, as listed by get_support_files).
        let filename: String
        /// Rows each student receives. Required unless `remove` is true.
        let sampleSize: Int?
        /// A column name to balance the sample across; omitted for a plain
        /// row sample.
        let stratumColumn: String?
        /// True to clear the dataset mark (the file becomes an ordinary shared
        /// support file again).
        let remove: Bool?
    }

    struct DatasetEntry: Encodable, Sendable {
        let file: String
        let sampleSize: Int?
        /// "rowSample" or "stratifiedSample" — reported so an agent can read
        /// back which kind of slice a file is marked for, not just that it is.
        let kind: String
        let stratumColumn: String?
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        /// Every dataset spec on the assignment after the edit.
        let datasets: [DatasetEntry]
    }

    static let name = "set_dataset"
    static let description =
        "Mark a bundled support file as a per-student DATASET, or clear the mark, by assignment "
        + "public ID. A dataset file is personalized at delivery: each student receives a "
        + "deterministic random sample of sampleSize data rows (keyed to their per-assignment seed) "
        + "under the SAME filename, so the notebook's read_csv(...) line is unchanged but every "
        + "student explores their own rows — in the editor, in browser grading, and on the worker. "
        + "The full uploaded file becomes the server-side pool; students never see it. Structural "
        + "checks (columns, dtypes, figure counts) are unaffected; exact-value checks against the "
        + "shared file would break, so pair datasets with structural or per-student checks. Pick "
        + "sampleSize large enough that every category a groupby exercise needs still appears — or "
        + "pass stratumColumn to have the sample balanced across that column's distinct values, "
        + "which guarantees every category survives into every student's copy (including a rare one "
        + "a plain sample would usually drop). A stratum column must exist in the file's header and "
        + "have no more distinct values than sampleSize; both are checked here, against the file. "
        + "Like "
        + "the web editor's dataset control this does not close the assignment or re-run validation "
        + "(the suite is unchanged); existing submissions pick up their slice on the next regrade. "
        + "List support files with get_support_files (dataset marks are reported there); pass "
        + "remove:true to make the file an ordinary shared support file again."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "filename": .object([
                "type": .string("string"),
                "description": .string(
                    "A bundled support filename (bare name, no path separators), e.g. \"cases.csv\"."),
            ]),
            "sampleSize": .object([
                "type": .string("integer"),
                "description": .string(
                    "Data rows each student receives (>= 1; the header row is always kept). "
                        + "Required unless remove is true."),
            ]),
            "stratumColumn": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional. A column name from the file's header; the sample is then apportioned "
                        + "across that column's distinct values so every category appears in every "
                        + "student's slice. Must have no more distinct values than sampleSize. Omit "
                        + "for a plain random row sample."),
            ]),
            "remove": .object([
                "type": .string("boolean"),
                "description": .string("True to clear the dataset mark for this file."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("filename")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "datasets": .object(["type": .string("array")]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("datasets")]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        // Datasets are content authoring — TA+, matching the web endpoint.
        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, tool: Self.name, atLeast: .ta)

        let remove = input.remove ?? false
        guard let cleaned = FilenameSafety.bareFilename(input.filename), cleaned == input.filename
        else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "filename must be a bare filename with no path components.")
        }

        if !remove {
            guard let sampleSize = input.sampleSize, sampleSize >= 1 else {
                throw MCPToolError.invalidArguments(
                    tool: Self.name,
                    detail: "sampleSize (>= 1) is required when marking a dataset; "
                        + "pass remove:true to clear a mark.")
            }
            // The file must be a bundled *support* file: a dataset marks
            // existing data as per-student, it never introduces a file, and a
            // graded script or canonical notebook can't be one.
            let zipEntries = Set(
                listZipEntries(zipPath: setup.zipPath).map { entry in
                    entry.hasPrefix("./") ? String(entry.dropFirst(2)) : entry
                })
            let suiteScripts = Set(setup.decodedManifest()?.testSuites.map(\.script) ?? [])
            guard zipEntries.contains(cleaned) else {
                throw MCPToolError.invalidArguments(
                    tool: Self.name,
                    detail: "\"\(cleaned)\" is not among this assignment's bundled files "
                        + "(list them with get_support_files; upload one with "
                        + "author_script(tier:\"support\")).")
            }
            guard !suiteScripts.contains(cleaned), cleaned != "assignment.ipynb",
                cleaned != "solution.ipynb"
            else {
                throw MCPToolError.invalidArguments(
                    tool: Self.name,
                    detail: "\"\(cleaned)\" is not a support file — only support data files can "
                        + "be per-student datasets.")
            }
            // The same check the web endpoints run, from the same place: a
            // stratum column has to exist in this file and have no more
            // categories than the sample has rows. The materializer degrades
            // quietly on both at delivery time, so this is where an agent finds
            // out — with the file's real column names in the message.
            if let issue = DatasetSpecValidation.issue(
                with: spec(from: input, filename: cleaned),
                sourceCSV: extractZipEntry(zipPath: setup.zipPath, entryName: cleaned)
                    .flatMap { String(data: $0, encoding: .utf8) })
            {
                throw MCPToolError.invalidArguments(tool: Self.name, detail: issue)
            }
        }

        let written = spec(from: input, filename: cleaned)
        try await mutateManifest(setup: setup, on: context.db) { dict in
            var specs = (dict["datasets"] as? [[String: Any]]) ?? []
            // Replaced, never appended — two specs for one file would disagree
            // about how many rows a student gets, and both PUT endpoints reject
            // such a pair outright.
            specs.removeAll { ($0["file"] as? String) == cleaned }
            if !remove {
                var entry: [String: Any] = ["file": cleaned, "kind": written.kind.rawValue]
                if let sampleSize = written.sampleSize { entry["sampleSize"] = sampleSize }
                if let column = written.stratumColumn { entry["stratumColumn"] = column }
                specs.append(entry)
            }
            if specs.isEmpty {
                dict.removeValue(forKey: "datasets")
            } else {
                dict["datasets"] = specs
            }
        }

        let datasets = (setup.decodedManifest()?.datasets ?? []).map {
            DatasetEntry(
                file: $0.file, sampleSize: $0.sampleSize,
                kind: $0.kind.rawValue, stratumColumn: $0.stratumColumn)
        }
        return Output(assignmentPublicID: assignment.publicID, datasets: datasets)
    }

    /// The spec this call would write, built once and used for both the
    /// validation and the manifest entry — so the thing that is checked is the
    /// thing that is stored.
    ///
    /// A blank `stratumColumn` reads as "no column": an agent clearing the
    /// field means a plain row sample, not a stratified spec that fails
    /// validation on the emptiness it just asked for.
    private func spec(from input: Input, filename: String) -> DatasetSpec {
        let column = input.stratumColumn?.trimmingCharacters(in: .whitespaces)
        let stratum = (column?.isEmpty ?? true) ? nil : column
        return DatasetSpec(
            file: filename,
            kind: stratum == nil ? .rowSample : .stratifiedSample,
            sampleSize: input.sampleSize,
            stratumColumn: stratum)
    }
}
