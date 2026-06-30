// APIServer/MCP/Tools/AuthorNotebookCheckTool.swift
//
// Write tool: create or replace a notebook check on an assignment, by public ID.
// content:write, course-scoped.  A notebook check is an instructor-authored
// single-shot assertion about a student's notebook submission (e.g. "is `df` a
// (250, 13) DataFrame?", "did the student produce >= 2 figures?", "does the
// source use a list comprehension?").  Until this tool existed, checks could be
// authored only in the browser editor — get_suite could read them and
// delete_suite_item / move_suite_item could remove or relocate them, but an
// agent could not create or edit one.
//
// Upsert by `id` (matching author_script's create-or-replace philosophy rather
// than the split create/update of the pattern-family tools): if a check with the
// id already exists its spec is replaced, otherwise a new check row is appended
// (contiguously within its section).  Read-modify-write through the same
// buildSuitePayload / applySuiteEdit path the editor uses, which renders the
// check's generated Python script AND runs the per-kind structural validation
// synchronously (so a malformed spec is rejected here, not silently shipped),
// then closes a currently-open assignment and re-kicks validation — exactly like
// the other content-edit write tools.
//
// The per-kind config fields are passed through loosely; which ones are required
// is enforced by the validator (e.g. data_frame_shape needs variable +
// expectedRows + expectedCols), matching how create_pattern_family delegates
// per-kind legality to the apply path.

import Core
import Fluent
import Foundation
import Vapor

struct AuthorNotebookCheckTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// Stable check id (unique within the assignment; reused as the
        /// generated-filename fragment). Reusing an existing id replaces it.
        let id: String
        /// One of the NotebookCheckKind raw values (data_frame_shape, …).
        let kind: String
        let name: String?
        let tier: String?
        let points: Int?
        let dependsOn: [String]?
        /// Existing section id to place the check in; nil = ungrouped (or, on
        /// replace, keep its current section).
        let sectionID: String?
        let hint: String?
        /// Check-level per-test execution time limit (seconds), in `1...600`,
        /// overriding the assignment default. 0 / omitted = inherit the default.
        let timeLimitSeconds: Int?

        // Per-kind config (the validator enforces which are required per kind).
        let variable: String?
        let expectedRows: Int?
        let expectedCols: Int?
        let expectedColumns: [String]?
        /// "exact" or "superset" (data_frame_columns).
        let columnMatch: String?
        let expectedCSV: String?
        let checkDtype: Bool?
        let checkLike: Bool?
        let rtol: Double?
        let atol: Double?
        let ignoreIndex: Bool?
        let expectedArray: [Double]?
        let minFigures: Int?
        let containsText: String?
        let regex: Bool?
        let mustDifferFrom: String?
        let expectedArity: Int?
        let expectedType: String?
        let requiredConstructs: [String]?

        init(
            assignmentPublicID: String, id: String, kind: String,
            name: String? = nil, tier: String? = nil, points: Int? = nil,
            dependsOn: [String]? = nil, sectionID: String? = nil, hint: String? = nil,
            timeLimitSeconds: Int? = nil,
            variable: String? = nil, expectedRows: Int? = nil, expectedCols: Int? = nil,
            expectedColumns: [String]? = nil, columnMatch: String? = nil, expectedCSV: String? = nil,
            checkDtype: Bool? = nil, checkLike: Bool? = nil, rtol: Double? = nil, atol: Double? = nil,
            ignoreIndex: Bool? = nil, expectedArray: [Double]? = nil, minFigures: Int? = nil,
            containsText: String? = nil, regex: Bool? = nil, mustDifferFrom: String? = nil,
            expectedArity: Int? = nil, expectedType: String? = nil, requiredConstructs: [String]? = nil
        ) {
            self.assignmentPublicID = assignmentPublicID
            self.id = id
            self.kind = kind
            self.name = name
            self.tier = tier
            self.points = points
            self.dependsOn = dependsOn
            self.sectionID = sectionID
            self.hint = hint
            self.timeLimitSeconds = timeLimitSeconds
            self.variable = variable
            self.expectedRows = expectedRows
            self.expectedCols = expectedCols
            self.expectedColumns = expectedColumns
            self.columnMatch = columnMatch
            self.expectedCSV = expectedCSV
            self.checkDtype = checkDtype
            self.checkLike = checkLike
            self.rtol = rtol
            self.atol = atol
            self.ignoreIndex = ignoreIndex
            self.expectedArray = expectedArray
            self.minFigures = minFigures
            self.containsText = containsText
            self.regex = regex
            self.mustDifferFrom = mustDifferFrom
            self.expectedArity = expectedArity
            self.expectedType = expectedType
            self.requiredConstructs = requiredConstructs
        }
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let checkID: String
        let kind: String
        /// true when a new check was created; false when an existing one was replaced.
        let created: Bool
        let validationStatus: String?
        /// true when this edit closed a previously-open (or preview) assignment.
        let assignmentClosed: Bool
    }

    static let name = "author_notebook_check"
    static let description =
        "Author a graded check about a student's notebook — preferred over a hand-written "
        + "author_script whenever the assertion is about a DataFrame/Series/array, a figure count, a "
        + "defined function or variable, or the notebook source. "
        + "Create or replace a notebook check on an assignment, by public ID — a single-shot assertion "
        + "about a student's notebook (e.g. is `df` a (rows, cols) DataFrame, did the notebook produce "
        + ">= N figures, does the source use a list comprehension). Provide a stable `id` (reusing an "
        + "existing id replaces that check), a `kind` (data_frame_shape / data_frame_columns / "
        + "data_frame_equality / series_equality / numeric_array_close / figure_count / cell_contains / "
        + "function_exists / variable_exists / ast_structure), and that kind's config fields — e.g. "
        + "data_frame_shape needs variable + expectedRows + expectedCols; figure_count needs minFigures; "
        + "cell_contains needs containsText; ast_structure needs requiredConstructs. Optional tier "
        + "(public/release/secret/student, default public), points, dependsOn, sectionID, a \"💡 "
        + "Hint\" shown on failure, and a per-test timeLimitSeconds (1–600s, overriding the assignment "
        + "default; 0 inherits it). Saving renders the check's script, validates it synchronously "
        + "(rejecting missing/!malformed kind fields), closes the assignment if it was open (reported as "
        + "`assignmentClosed`), and re-runs validation. Read existing checks (and their exact specs) "
        + "from get_suite; remove one with delete_suite_item."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "id": .object([
                "type": .string("string"),
                "description": .string("Stable check id (unique; reusing an existing id replaces it)."),
            ]),
            "kind": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("data_frame_shape"), .string("data_frame_columns"),
                    .string("data_frame_equality"), .string("series_equality"),
                    .string("numeric_array_close"), .string("figure_count"),
                    .string("cell_contains"), .string("function_exists"),
                    .string("variable_exists"), .string("ast_structure"),
                ]),
            ]),
            "name": .object([
                "type": .string("string"),
                "description": .string("Display name shown in the results view; omit for an auto label."),
            ]),
            "tier": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("public"), .string("release"), .string("secret"), .string("student"),
                ]),
                "description": .string("Visibility tier; default public."),
            ]),
            "points": .object(["type": .string("integer"), "description": .string("Default 1.")]),
            "dependsOn": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
                "description": .string("Prerequisite script names or family:<id> tokens."),
            ]),
            "sectionID": .object([
                "type": .string("string"),
                "description": .string("Existing section id to group under; omit for ungrouped."),
            ]),
            "hint": .object([
                "type": .string("string"),
                "description": .string("\"💡 Hint\" shown to the student only when this check fails."),
            ]),
            "timeLimitSeconds": .object([
                "type": .string("integer"),
                "description": .string(
                    "Per-test execution time limit (seconds, 1–600) for this check, overriding the "
                        + "assignment default. Omit / 0 to inherit the default."),
            ]),
            "variable": .object([
                "type": .string("string"),
                "description": .string(
                    "Module-level name to inspect (data_frame_*/series/numeric_array/variable_exists), "
                        + "or the function name (function_exists)."),
            ]),
            "expectedRows": .object([
                "type": .string("integer"), "description": .string("data_frame_shape: required row count."),
            ]),
            "expectedCols": .object([
                "type": .string("integer"), "description": .string("data_frame_shape: required column count."),
            ]),
            "expectedColumns": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
                "description": .string("data_frame_columns: the expected column names."),
            ]),
            "columnMatch": .object([
                "type": .string("string"), "enum": .array([.string("exact"), .string("superset")]),
                "description": .string("data_frame_columns: match mode (default exact)."),
            ]),
            "expectedCSV": .object([
                "type": .string("string"),
                "description": .string("data_frame_equality / series_equality: expected value as CSV."),
            ]),
            "checkDtype": .object([
                "type": .string("boolean"), "description": .string("data_frame_equality: check dtypes (default true)."),
            ]),
            "checkLike": .object([
                "type": .string("boolean"),
                "description": .string("data_frame_equality: ignore row/column order (default false)."),
            ]),
            "rtol": .object([
                "type": .string("number"),
                "description": .string("data_frame_equality / numeric_array_close: relative tolerance."),
            ]),
            "atol": .object([
                "type": .string("number"),
                "description": .string("data_frame_equality / numeric_array_close: absolute tolerance."),
            ]),
            "ignoreIndex": .object([
                "type": .string("boolean"),
                "description": .string(
                    "data_frame_equality / series_equality: reset index before comparing (default true)."),
            ]),
            "expectedArray": .object([
                "type": .string("array"), "items": .object(["type": .string("number")]),
                "description": .string("numeric_array_close: the expected 1D numeric array."),
            ]),
            "minFigures": .object([
                "type": .string("integer"), "description": .string("figure_count: minimum matplotlib figures."),
            ]),
            "containsText": .object([
                "type": .string("string"),
                "description": .string("cell_contains: substring (or regex) a code cell must contain."),
            ]),
            "regex": .object([
                "type": .string("boolean"), "description": .string("cell_contains: treat containsText as a regex."),
            ]),
            "mustDifferFrom": .object([
                "type": .string("string"),
                "description": .string("cell_contains: reference the matched cell must NOT equal."),
            ]),
            "expectedArity": .object([
                "type": .string("integer"),
                "description": .string("function_exists: exact positional-parameter count."),
            ]),
            "expectedType": .object([
                "type": .string("string"),
                "description": .string("variable_exists: required runtime type (e.g. \"int\", \"DataFrame\")."),
            ]),
            "requiredConstructs": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
                "description": .string(
                    "ast_structure: predicates like \"for_loop\", \"recursion\", \"import:math\", "
                        + "or negated (\"!for_loop\")."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("id"), .string("kind")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object(["type": .string("string")]),
            "checkID": .object(["type": .string("string")]),
            "kind": .object(["type": .string("string")]),
            "created": .object(["type": .string("boolean")]),
            "validationStatus": .object(["type": .string("string")]),
            "assignmentClosed": .object(["type": .string("boolean")]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("checkID"), .string("kind"), .string("created"),
            .string("assignmentClosed"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        guard let kind = NotebookCheckKind(rawValue: input.kind) else {
            throw MCPToolError.invalidArguments(tool: Self.name, detail: "Unknown check kind \"\(input.kind)\".")
        }
        let checkID = input.id.trimmingCharacters(in: .whitespaces)
        guard !checkID.isEmpty else {
            throw MCPToolError.invalidArguments(tool: Self.name, detail: "Check id must not be empty.")
        }
        let tier = try Self.parseTier(input.tier)
        let columnMatch = try Self.parseColumnMatch(input.columnMatch)

        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, tool: Self.name)

        var payload = buildSuitePayload(fromManifest: setup.manifest, zipPath: setup.zipPath)
        let existingIndex = payload.items.firstIndex { $0.kind == "check" && $0.check?.id == checkID }

        // A provided section must exist; on replace, omitting it keeps the row's
        // current section.
        let requestedSection = input.sectionID.flatMap { $0.isEmpty ? nil : $0 }
        if let requestedSection, !payload.sections.contains(where: { $0.id == requestedSection }) {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "No section with id \"\(requestedSection)\". Create it with create_suite_section first.")
        }
        let sectionID =
            requestedSection
            ?? (existingIndex.flatMap { payload.items[$0].sectionID })

        let check = try Self.buildCheck(
            input, id: checkID, kind: kind, tier: tier, columnMatch: columnMatch,
            sectionID: sectionID)
        let row = SuiteItemDTO(
            kind: "check", script: nil, family: nil, check: check,
            dependsOn: nil, sectionID: sectionID)

        let created: Bool
        if let existingIndex {
            payload.items[existingIndex] = row
            created = false
        } else {
            payload.items = Self.insert(row, into: payload.items, sectionID: sectionID)
            created = true
        }

        try await applySuiteEditMapped(setup: setup, body: payload, tool: Self.name, on: context.db)
        // Close, re-grade, and re-validate (matching the web Save button).
        let closed = try await finalizeContentEdit(
            assignment: assignment, setup: setup, context: context, retest: true)

        return Output(
            assignmentPublicID: assignment.publicID,
            checkID: checkID,
            kind: kind.rawValue,
            created: created,
            validationStatus: assignment.validationStatus,
            assignmentClosed: closed)
    }

    private static func parseTier(_ raw: String?) throws -> TestTier {
        guard let raw else { return .pub }
        guard let tier = TestTier(rawValue: raw) else {
            throw MCPToolError.invalidArguments(
                tool: name, detail: "tier must be one of: public, release, secret, student.")
        }
        return tier
    }

    private static func parseColumnMatch(_ raw: String?) throws -> ColumnMatchMode? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let mode = ColumnMatchMode(rawValue: raw) else {
            throw MCPToolError.invalidArguments(
                tool: name, detail: "columnMatch must be \"exact\" or \"superset\".")
        }
        return mode
    }

    /// Normalizes the check-level time limit: nil/0 → nil (inherit the default),
    /// any non-zero value bound-checked to `1...600`.
    private static func normalizedTimeLimit(_ raw: Int?) throws -> Int? {
        guard let raw, raw != 0 else { return nil }
        return try validateTimeLimitSeconds(raw, tool: name, field: "timeLimitSeconds")
    }

    /// Builds the `NotebookCheck` from the input; per-kind field legality is left
    /// to the validator that runs inside applySuiteEdit. The time limit is
    /// normalized here (0/nil → nil; non-zero bound-checked to 1...600).
    private static func buildCheck(
        _ input: Input, id: String, kind: NotebookCheckKind, tier: TestTier,
        columnMatch: ColumnMatchMode?, sectionID: String?
    ) throws -> NotebookCheck {
        NotebookCheck(
            id: id,
            name: input.name.flatMap { $0.isEmpty ? nil : $0 },
            kind: kind,
            tier: tier,
            points: input.points ?? 1,
            dependsOn: input.dependsOn ?? [],
            sectionID: sectionID,
            hint: input.hint.flatMap { $0.isEmpty ? nil : $0 },
            timeLimitSeconds: try normalizedTimeLimit(input.timeLimitSeconds),
            variable: input.variable,
            expectedRows: input.expectedRows,
            expectedCols: input.expectedCols,
            expectedColumns: input.expectedColumns,
            columnMatch: columnMatch,
            expectedCSV: input.expectedCSV,
            checkDtype: input.checkDtype,
            checkLike: input.checkLike,
            rtol: input.rtol,
            atol: input.atol,
            ignoreIndex: input.ignoreIndex,
            expectedArray: input.expectedArray,
            minFigures: input.minFigures,
            containsText: input.containsText,
            regex: input.regex,
            mustDifferFrom: input.mustDifferFrom,
            expectedArity: input.expectedArity,
            expectedType: input.expectedType,
            requiredConstructs: input.requiredConstructs)
    }

    /// Inserts the new check row immediately after the last existing item in the
    /// same section (keeping that section's block contiguous, which
    /// applyPatternFamilies requires); appends at the end when ungrouped/empty.
    private static func insert(
        _ row: SuiteItemDTO, into items: [SuiteItemDTO], sectionID: String?
    ) -> [SuiteItemDTO] {
        var result = items
        if let sectionID, !sectionID.isEmpty,
            let lastInSection = items.lastIndex(where: { $0.sectionID == sectionID })
        {
            result.insert(row, at: lastInSection + 1)
        } else {
            result.append(row)
        }
        return result
    }
}
