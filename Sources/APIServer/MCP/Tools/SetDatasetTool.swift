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
        /// Rows each student receives. Omitted keeps the stored sample. A file
        /// with no sample yet needs one, unless `remove` is true.
        let sampleSize: Int?
        /// A column name to balance the sample across; omitted for a plain
        /// row sample.
        let stratumColumn: String?
        /// True to clear the dataset mark (the file becomes an ordinary shared
        /// support file again).
        let remove: Bool?
        /// Derivation steps applied after sampling. Omitted means "leave whatever
        /// is already there" — an agent adjusting sampleSize must not silently
        /// drop the transforms it was not asked about. Send `[]` to clear them.
        let transforms: [TransformInput]?
        /// The number of parts of a partition (docs/datasets-course-library.md
        /// §4.11). Omitted keeps the stored kind; 0 turns a partition back
        /// into a sample.
        let partCount: Int?
        /// True to give every student the whole file: no sample, no stratum,
        /// no partition. The transforms follow `transforms` as usual. With no
        /// transforms, a library attachment keeps its spec with no sample and
        /// any other file loses its dataset mark; either way every student
        /// reads one linked copy.
        let wholeFile: Bool?

        init(
            assignmentPublicID: String, filename: String, sampleSize: Int?, stratumColumn: String?, remove: Bool?,
            transforms: [TransformInput]?, partCount: Int? = nil, wholeFile: Bool? = nil
        ) {
            self.assignmentPublicID = assignmentPublicID
            self.filename = filename
            self.sampleSize = sampleSize
            self.stratumColumn = stratumColumn
            self.remove = remove
            self.transforms = transforms
            self.partCount = partCount
            self.wholeFile = wholeFile
        }
    }

    struct TransformInput: Decodable, Sendable {
        let kind: String
        let columns: [String]?
        let rate: Double?
    }

    struct DatasetEntry: Encodable, Sendable {
        let file: String
        let sampleSize: Int?
        /// A `DatasetKind` raw value — reported so an agent can read back which
        /// kind of slice a file is marked for, not just that it is.
        let kind: String
        let stratumColumn: String?
        /// Reported for the same reason as `kind`: an agent that cannot read a
        /// file's transforms back cannot tell whether its edit preserved them.
        let transforms: [TransformEntry]
        /// The number of parts of a partition; nil for the other kinds.
        var partCount: Int?
        /// A `DatasetDeliveryMode` raw value: "shared" when every student
        /// reads one linked copy, "perPart" when each part is stored once,
        /// "perStudent" when each student stores a file of their own.
        var datasetDelivery: String
    }

    struct TransformEntry: Encodable, Sendable {
        let kind: String
        let columns: [String]
        let rate: Double?
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        /// Every dataset spec on the assignment after the edit.
        let datasets: [DatasetEntry]
        /// What the save changed beyond what was asked: a sample that covers
        /// the whole file is stored as no sample, or the mark is cleared.
        let notes: [String]
        /// A stored spec whose sample covers its whole file, so every student
        /// stores a private copy of the same bytes. Each names its fix.
        let warnings: [String]
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
        + "remove:true to make the file an ordinary shared support file again. A FHIR NDJSON file "
        + "(datasetFormat fhirNdjson) is delivered whole, so a sample size, a stratum column, a partition "
        + "and transforms are refused on it; it becomes a dataset only through the course library "
        + "(create_dataset, then attach_dataset), and every edit here keeps its format. To give every student the "
        + "WHOLE file, pass wholeFile:true, never a sampleSize equal to the row count: it clears the sample, "
        + "the stratum and the partition, and works on a file attached from the course library too (whose "
        + "spec cannot be removed); on any other file it clears the mark, as remove:true does. On a library "
        + "attachment a sampleSize at or above the file's data-row count is stored as no sample, and notes "
        + "says so. Each "
        + "dataset in the result reports datasetDelivery: \"shared\" (every student reads one linked copy), "
        + "\"perPart\" or \"perStudent\" (each student stores a file of their own); warnings names any "
        + "stored sample that still gives the whole file per student. "
        + MCPActivityProse.sharedDataRule
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
                        + "Omitted keeps the stored sample. Required for a file that has no sample yet, "
                        + "unless remove is true."),
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
                "description": .string(
                    "True to clear the dataset mark for this file. Refused for a file attached from the course "
                        + "library; use wholeFile or detach_dataset."),
            ]),
            "wholeFile": .object([
                "type": .string("boolean"),
                "description": .string(
                    "True to give every student the whole file: clears sampleSize, stratumColumn and "
                        + "partCount (do not send them with it). Transforms follow the transforms field as "
                        + "usual; with none, every student reads one linked copy (datasetDelivery \"shared\"). "
                        + "Works on a library attachment, which keeps its source and scope."),
            ]),
            "partCount": .object([
                "type": .string("integer"),
                "description": .string(
                    "Optional. Split the file into this many disjoint parts (2 or more, at most the "
                        + "number of data rows) and give each student one part: data row i is in part "
                        + "i mod partCount, and the student's part is dealt, not drawn, so the class fills "
                        + "the parts in turn. A partition takes no sampleSize and no stratumColumn; a "
                        + "stored sample is dropped. A job with no student (the class corpus run) gets the "
                        + "whole file, and a solution run gets part 0. Omit to keep the stored kind; send "
                        + "0 to turn a partition back into a sample (with a sampleSize); to give the whole "
                        + "file instead, send wholeFile:true."),
            ]),
            "transforms": .object([
                "type": .string("array"),
                "description": .string(
                    "Optional. Derivation steps applied to the student's rows AFTER sampling, in "
                        + "order. Sampling decides which rows a student gets; a transform alters the "
                        + "values in them, so the pool becomes a template each student varies on. "
                        + "Kinds: " + DatasetTransformProse.glossary + ". Each step takes columns (an "
                        + "explicit list of header names — there is no wildcard, so a column a "
                        + "notebook check asserts on cannot be altered by accident) and rate (the "
                        + "fraction of the student's rows affected, above 0 and at most 1). A "
                        + "transform never adds, removes, renames or reorders a column. Note this "
                        + "changes the cells a student computes over, and a per-student expression "
                        + "reads them as delivered, so pair it with per-student expected values rather "
                        + "than a fixed one. OMIT this to leave existing "
                        + "transforms untouched; send [] to clear them."),
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
            "notes": .object(["type": .string("array"), "items": MCPSchema.string]),
            "warnings": .object(["type": .string("array"), "items": MCPSchema.string]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("datasets"), .string("notes"), .string("warnings"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        // Datasets are content authoring — TA+, matching the web endpoint.
        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, atLeast: .ta)

        let remove = input.remove ?? false
        guard let cleaned = FilenameSafety.bareFilename(input.filename), cleaned == input.filename
        else {
            throw MCPToolError.invalidArguments(detail: "filename must be a bare filename with no path components.")
        }

        // Built once, from the stored spec plus this call's changes, and used
        // for both the validation and the manifest entry — so the thing that is
        // checked is the thing that is stored.
        let existing = setup.decodedManifest()?.datasetSpecsByFile[cleaned]
        let wholeFile = try Self.wholeFileRequested(by: input)
        let written = spec(from: input, wholeFile: wholeFile, filename: cleaned, existing: existing)
        // The whole file with nothing to vary it and no library source is an
        // ordinary support file: a spec would do nothing, and validation
        // refuses one. A library spec keeps its source, so it stays, with no
        // sample.
        let clearsMark = !remove && wholeFile && written.isShared && written.source == nil
        // The shared refusal of a spec that does nothing is worded for every
        // door; this one names the MCP way to the whole file. A file that has
        // no spec yet still needs a sample size, as before.
        if !remove, !wholeFile, written.sampleSize == nil, written.isShared, written.source == nil,
            existing != nil
        {
            throw MCPToolError.invalidArguments(
                detail: "'\(cleaned)' needs a sampleSize of 1 or more. To give every student the whole file, "
                    + "send wholeFile:true instead.")
        }
        var notes: [String] = []
        if clearsMark, existing != nil {
            notes.append(
                "'\(cleaned)': the whole file with no transforms needs no dataset mark, so the mark was cleared "
                    + "and the file is an ordinary support file (every student reads one copy). An upload-only "
                    + "assignment's submit page no longer offers it for download.")
        }

        // The one dataset edit, which the web `PUT /datasets` routes run too
        // (#2771). It refuses a spec that `datasetSpecRefusal` refuses, and a
        // remove of a file attached from the course library: that spec is
        // ended by a detach, which keeps the sample, while a plain remove
        // would give every student the whole file. Replaced, never appended,
        // so one file never has two specs.
        do {
            let normalized = try await applyDatasetsEdit(
                setup: setup, change: .replace(file: cleaned, with: remove || clearsMark ? nil : written),
                on: context.db)
            notes += normalized.map(\.note)
        } catch let refusal as DatasetsEditError {
            throw MCPToolError.invalidArguments(detail: refusal.description)
        }

        let stored = setup.decodedManifest()?.datasets ?? []
        let datasets = stored.map {
            DatasetEntry(
                file: $0.file, sampleSize: $0.sampleSize,
                kind: $0.kind.rawValue, stratumColumn: $0.stratumColumn,
                transforms: $0.transforms.map {
                    TransformEntry(kind: $0.kind.rawValue, columns: $0.columns, rate: $0.rate)
                }, partCount: $0.partCount, datasetDelivery: $0.deliveryMode.rawValue)
        }
        // A spec of another file that this call did not save is not
        // normalized, so it is reported instead.
        let warnings = await wholeFilePerStudentSamples(in: stored, zipPath: setup.zipPath)
            .map { "\($0.message) \($0.fix)" }
        return Output(assignmentPublicID: assignment.publicID, datasets: datasets, notes: notes, warnings: warnings)
    }

    /// True when the call sends `wholeFile: true`. Refuses it with a field
    /// that selects rows, which it would contradict.
    ///
    /// Only the explicit flag asks for the whole file. Ending a partition
    /// (`partCount: 0`) with no sample size is still refused for a file not
    /// attached from the library: the caller may have meant a sample and
    /// forgotten its size, and the refusal names `wholeFile`.
    private static func wholeFileRequested(by input: Input) throws(MCPToolError) -> Bool {
        guard input.wholeFile == true else { return false }
        let stratum = input.stratumColumn?.trimmingCharacters(in: .whitespaces) ?? ""
        guard input.sampleSize == nil, (input.partCount ?? 0) == 0, stratum.isEmpty, input.remove != true else {
            throw MCPToolError.invalidArguments(
                detail: "wholeFile gives every student every row, so it takes no sampleSize, stratumColumn, "
                    + "partCount or remove.")
        }
        return true
    }

    /// The spec this call would write, built once and used for both the
    /// validation and the manifest entry — so the thing that is checked is the
    /// thing that is stored.
    ///
    /// A blank `stratumColumn` reads as "no column": an agent clearing the
    /// field means a plain row sample, not a stratified spec that fails
    /// validation on the emptiness it just asked for.
    private func spec(from input: Input, wholeFile: Bool, filename: String, existing: DatasetSpec?) -> DatasetSpec {
        if wholeFile {
            return DatasetSpec(
                file: filename, kind: .rowSample,
                transforms: input.transforms.map(Self.transforms(from:)) ?? existing?.transforms ?? [],
                source: existing?.source, scope: existing?.scope ?? .assignment, format: existing?.format ?? .csv)
        }
        let column = input.stratumColumn?.trimmingCharacters(in: .whitespaces)
        let stratum = (column?.isEmpty ?? true) ? nil : column
        // Omitted keeps a stored partition, as for the other fields; 0 ends
        // it. A partition replaces the sample, so a stored sample size is not
        // carried into one, and one that the caller sends is refused.
        let partCount: Int?
        switch input.partCount {
        case .some(0): partCount = nil
        case .some(let count): partCount = count
        case .none: partCount = existing?.kind == .partition ? existing?.partCount : nil
        }
        let kind: DatasetKind = partCount != nil ? .partition : (stratum == nil ? .rowSample : .stratifiedSample)
        return DatasetSpec(
            file: filename,
            kind: kind,
            // Omitted means "keep the stored sample", as for `transforms`: an
            // agent changing only the stratum must not turn a sample into the
            // whole file.
            sampleSize: kind == .partition ? input.sampleSize : input.sampleSize ?? existing?.sampleSize,
            stratumColumn: stratum,
            // Omitted means "leave them alone". Rebuilding a spec from only the
            // fields a caller mentioned is how this surface twice came within a
            // release of downgrading data it did not understand; a field is
            // dropped here only when the caller says so, by sending [].
            transforms: input.transforms.map(Self.transforms(from:)) ?? existing?.transforms ?? [],
            // The library fields are not this tool's to change: the library
            // attach path writes them, and every other door carries them.
            source: existing?.source,
            scope: existing?.scope ?? .assignment,
            partCount: partCount,
            // The format is the library attach path's to set, like the
            // library fields above; this door carries it.
            format: existing?.format ?? .csv,
            // An unknown format is carried too, so the save checks refuse the
            // edit rather than store the spec as CSV.
            unknownFormat: existing?.unknownFormat)
    }

    /// Maps the wire shape to the model. An unrecognised kind is dropped rather
    /// than guessed at — validation then refuses the spec, naming what is
    /// supported, instead of silently storing a step that would never run.
    private static func transforms(from inputs: [TransformInput]) -> [DatasetTransform] {
        inputs.compactMap { input in
            guard let kind = DatasetTransform.Kind(rawValue: input.kind) else { return nil }
            return DatasetTransform(kind: kind, columns: input.columns ?? [], rate: input.rate)
        }
    }
}
