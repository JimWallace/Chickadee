// APIServer/MCP/Tools/CreatePatternFamilyTool.swift
//
// Write tool: create a NEW pattern family on an assignment.  content:write,
// course-scoped.  Complements update_pattern_family (which only edits an
// existing family): until this tool existed, families could be born only in
// the browser editor, so an agent could not author a family from scratch.
//
// Read-modify-write through the same buildSuitePayload / applySuiteEdit path
// the web editor and update_pattern_family use: loads the current authored
// suite, appends a new "family" row (placed contiguously within its section),
// and re-saves — which renders the family's scripts AND runs the structural +
// per-kind validation synchronously (arg count vs paramNames, the per-kind
// `expected` shape, `$var` ref resolution, filename clashes, dependency
// cycles).  A malformed spec is rejected here, not silently shipped.
//
// `args` / `expected` ride as raw JSON values so types are faithful (a string
// stays a string).  Per-case `argVarRefs` / `expectedVarRef` reference
// per-student `=` expressions (issue #461); the validator enforces which kinds
// may use them.

import Core
import Fluent
import Foundation
import Vapor

struct CreatePatternFamilyTool: ContentTool {
    /// One case of the new family. `key` is required; `args` defaults to `[]`
    /// (0-arg function) and `expected` to null when omitted (e.g. when
    /// `expectedVarRef` supplies the per-student expected instead).
    struct CaseInput: Decodable, Sendable {
        let key: String
        let label: String?
        let args: [JSONValue]?
        let expected: JSONValue?
        /// Parallel to `args`: `$`-less variable name for a per-student/section/
        /// family ref at that position, or null for the literal in `args`.
        let argVarRefs: [String?]?
        /// Parallel to `args`: false omits that argument (Python default applies).
        let argsProvided: [Bool]?
        /// Per-student expected: name of a global/section `=` expression resolved
        /// for the student's seed at grading time (validator enforces eligible kinds).
        let expectedVarRef: String?
        /// Per-case "💡 Hint" shown to the student only when this case fails;
        /// overrides the family-wide `defaultHint`. Omitted/empty = no per-case hint.
        let hint: String?
        let points: Int?
        let tier: String?
        /// Per-case execution time limit (seconds), in `1...600`, overriding the
        /// family default. 0 / omitted = no per-case override.
        let timeLimitSeconds: Int?
        let enabled: Bool?

        init(
            key: String, label: String? = nil, args: [JSONValue]? = nil, expected: JSONValue? = nil,
            argVarRefs: [String?]? = nil, argsProvided: [Bool]? = nil, expectedVarRef: String? = nil,
            hint: String? = nil, points: Int? = nil, tier: String? = nil,
            timeLimitSeconds: Int? = nil, enabled: Bool? = nil
        ) {
            self.key = key
            self.label = label
            self.args = args
            self.expected = expected
            self.argVarRefs = argVarRefs
            self.argsProvided = argsProvided
            self.expectedVarRef = expectedVarRef
            self.hint = hint
            self.points = points
            self.tier = tier
            self.timeLimitSeconds = timeLimitSeconds
            self.enabled = enabled
        }
    }

    struct VariableInput: Decodable, Sendable {
        let name: String
        let value: JSONValue
    }

    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// Stable family id (unique within the assignment; reused as the
        /// generated-filename infix). Must not already exist.
        let id: String
        let name: String
        /// One of the PatternKind raw values (boundary_equality, …).
        let kind: String
        /// The student function the family calls (required for all kinds except
        /// variable_equality, where the case args carry the variable name).
        let function: String?
        let paramNames: [String]?
        let defaultTier: String?
        let defaultPoints: Int?
        /// Family-wide "💡 Hint" applied to any case that has no per-case `hint`.
        let defaultHint: String?
        /// Family-level per-test execution time limit (seconds), in `1...600`,
        /// applied to every generated entry (cases + existence guard) without a
        /// per-case override. 0 / omitted = inherit the assignment default.
        let defaultTimeLimitSeconds: Int?
        let tolerance: Double?
        /// Existing section id to place the family in; nil = ungrouped.
        let sectionID: String?
        let dependsOn: [String]?
        let variables: [VariableInput]?
        let cases: [CaseInput]

        init(
            assignmentPublicID: String, id: String, name: String, kind: String,
            function: String? = nil, paramNames: [String]? = nil,
            defaultTier: String? = nil, defaultPoints: Int? = nil, defaultHint: String? = nil,
            defaultTimeLimitSeconds: Int? = nil,
            tolerance: Double? = nil, sectionID: String? = nil, dependsOn: [String]? = nil,
            variables: [VariableInput]? = nil, cases: [CaseInput]
        ) {
            self.assignmentPublicID = assignmentPublicID
            self.id = id
            self.name = name
            self.kind = kind
            self.function = function
            self.paramNames = paramNames
            self.defaultTier = defaultTier
            self.defaultPoints = defaultPoints
            self.defaultHint = defaultHint
            self.defaultTimeLimitSeconds = defaultTimeLimitSeconds
            self.tolerance = tolerance
            self.sectionID = sectionID
            self.dependsOn = dependsOn
            self.variables = variables
            self.cases = cases
        }
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let familyID: String
        let kind: String
        let caseKeys: [String]
        let validationStatus: String?
        /// true when this edit closed a previously-open (or preview) assignment.
        let assignmentClosed: Bool
    }

    static let name = "create_pattern_family"
    static let description =
        "Author a graded test as a pattern family — preferred over a hand-written author_script "
        + "whenever the check is a function-call assertion (equality, float tolerance, return type, "
        + "expected exception, performance bound, or stdout). "
        + "Create a NEW pattern family on an assignment, by public ID. Provide the family `id` "
        + "(unique; not an existing family), `name`, `kind` (boundary_equality / approximate_equality "
        + "/ variable_equality / return_type_check / exception_expected / performance_threshold / "
        + "stdout_equality / unordered_equality), the `function` it tests, `paramNames`, and a "
        + "non-empty `cases` list — each "
        + "case a { key, args, expected } with raw-JSON args (in parameter order) and expected return. "
        + "Cases may personalize via argVarRefs / expectedVarRef (names of global/section = expressions). "
        + "For function-calling kinds an existence guard (`<function> is defined`, 0 points) is generated "
        + "automatically and every case dependsOn it, so a missing/non-callable function fails once and "
        + "the cases skip — you don't need a separate function_exists check. "
        + "Set a `defaultHint` (family-wide) and/or per-case `hint` to give the student a \"💡 Hint\" "
        + "shown only when that test fails (per-case overrides the family default). "
        + "Set a family-level `defaultTimeLimitSeconds` and/or per-case `timeLimitSeconds` "
        + "(per-test execution time limit, 1–600s, overriding the assignment default). "
        + "Saving renders the family's scripts and runs validation synchronously, rejecting a wrong arg "
        + "count, an expected of the wrong shape for the kind, an unknown $ref, or a duplicate id. It "
        + "also closes the assignment if it was open (reported as `assignmentClosed`; re-open with "
        + "update_assignment once validation passes). To edit a family afterwards use update_pattern_family."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "id": .object([
                "type": .string("string"),
                "description": .string("New family id (unique; must not already exist)."),
            ]),
            "name": .object([
                "type": .string("string"), "description": .string("Human-readable family name."),
            ]),
            "kind": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("boundary_equality"), .string("approximate_equality"),
                    .string("variable_equality"), .string("return_type_check"),
                    .string("exception_expected"), .string("performance_threshold"),
                    .string("stdout_equality"), .string("unordered_equality"),
                ]),
            ]),
            "function": .object([
                "type": .string("string"),
                "description": .string("Student function the family calls (omit for variable_equality)."),
            ]),
            "paramNames": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
                "description": .string("Parameter names, in order (drives arg-count validation)."),
            ]),
            "defaultTier": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("public"), .string("release"), .string("secret"), .string("student"),
                ]),
            ]),
            "defaultPoints": .object(["type": .string("integer")]),
            "defaultHint": .object([
                "type": .string("string"),
                "description": .string(
                    "Family-wide \"💡 Hint\" shown to the student on any failing case that has no "
                        + "per-case hint."),
            ]),
            "defaultTimeLimitSeconds": .object([
                "type": .string("integer"),
                "description": .string(
                    "Family-level per-test execution time limit (seconds, 1–600) for every generated "
                        + "entry without a per-case override. Omit / 0 to inherit the assignment default."),
            ]),
            "tolerance": .object([
                "type": .string("number"),
                "description": .string("Float tolerance for approximate_equality (default 1e-6)."),
            ]),
            "sectionID": .object([
                "type": .string("string"),
                "description": .string("Existing section id to group under; omit for ungrouped."),
            ]),
            "dependsOn": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
                "description": .string("Prerequisite script names or family:<id> tokens."),
            ]),
            "variables": .object([
                "type": .string("array"),
                "description": .string("Family-scoped literal variables referenced from arg cells via $name."),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string")]),
                        "value": .object(["description": .string("Any JSON value.")]),
                    ]),
                    "required": .array([.string("name"), .string("value")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
            "cases": .object([
                "type": .string("array"),
                "description": .string("Non-empty list of cases."),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "key": .object([
                            "type": .string("string"),
                            "description": .string("Unique case key (also part of the generated filename)."),
                        ]),
                        "label": .object(["type": .string("string")]),
                        "args": .object([
                            "type": .string("array"),
                            "description": .string("Args in parameter order (raw JSON values)."),
                        ]),
                        "expected": .object([
                            "description": .string("Expected return (raw JSON), shape per kind.")
                        ]),
                        "argVarRefs": .object([
                            "type": .string("array"),
                            "description": .string("Parallel to args: \"name\" for a $var ref, or null."),
                        ]),
                        "argsProvided": .object([
                            "type": .string("array"),
                            "description": .string("Parallel to args: false omits the arg (Python default)."),
                        ]),
                        "expectedVarRef": .object([
                            "type": .string("string"),
                            "description": .string("Per-student expected: name of a = expression."),
                        ]),
                        "hint": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Per-case \"💡 Hint\" shown when this case fails (overrides defaultHint)."),
                        ]),
                        "points": .object(["type": .string("integer")]),
                        "tier": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("public"), .string("release"), .string("secret"),
                                .string("student"),
                            ]),
                        ]),
                        "timeLimitSeconds": .object([
                            "type": .string("integer"),
                            "description": .string(
                                "Per-case execution time limit (seconds, 1–600), overriding the family "
                                    + "default. Omit / 0 for no per-case override."),
                        ]),
                        "enabled": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("key")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("id"), .string("name"), .string("kind"),
            .string("cases"),
        ]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object(["type": .string("string")]),
            "familyID": .object(["type": .string("string")]),
            "kind": .object(["type": .string("string")]),
            "caseKeys": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
            ]),
            "validationStatus": .object(["type": .string("string")]),
            "assignmentClosed": .object(["type": .string("boolean")]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("familyID"), .string("kind"), .string("caseKeys"),
            .string("assignmentClosed"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: false)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        guard let kind = PatternKind(rawValue: input.kind) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "Unknown kind \"\(input.kind)\".")
        }
        let trimmedID = input.id.trimmingCharacters(in: .whitespaces)
        guard !trimmedID.isEmpty else {
            throw MCPToolError.invalidArguments(tool: Self.name, detail: "Family id must not be empty.")
        }
        guard !input.cases.isEmpty else {
            throw MCPToolError.invalidArguments(tool: Self.name, detail: "Provide at least one case.")
        }
        try Self.assertUniqueCaseKeys(input.cases, tool: Self.name)

        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, tool: Self.name, atLeast: .ta)

        var payload = buildSuitePayload(fromManifest: setup.manifest, zipPath: setup.zipPath)
        guard
            !payload.items.contains(where: { $0.kind == "family" && $0.family?.id == trimmedID })
        else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "A pattern family with id \"\(trimmedID)\" already exists; use update_pattern_family.")
        }

        let family = try Self.buildFamily(input, id: trimmedID, kind: kind)
        let row = SuiteItemDTO(
            kind: "family", script: nil, family: family, check: nil,
            dependsOn: family.dependsOn, sectionID: input.sectionID)
        payload.items = Self.insert(row, into: payload.items, sectionID: input.sectionID)

        // applySuiteEdit -> applyPatternFamilies -> validatePatternFamilies runs
        // the structural + per-kind checks synchronously; surface those as clean
        // MCP errors rather than opaque protocol failures.
        try await applySuiteEditMapped(setup: setup, body: payload, tool: Self.name, on: context.db)
        // Close, re-grade, and re-validate (matching the web Save button).
        let closed = try await finalizeContentEdit(
            assignment: assignment, setup: setup, context: context, retest: true)

        return Output(
            assignmentPublicID: assignment.publicID,
            familyID: family.id,
            kind: family.kind.rawValue,
            caseKeys: family.cases.map(\.key),
            validationStatus: assignment.validationStatus,
            assignmentClosed: closed)
    }

    /// Rejects empty or duplicate case keys.  Shared with
    /// update_pattern_family's `addCases` path, so it takes the calling tool's
    /// name for the error.
    static func assertUniqueCaseKeys(_ cases: [CaseInput], tool: String) throws {
        var seen = Set<String>()
        for c in cases {
            let key = c.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                throw MCPToolError.invalidArguments(tool: tool, detail: "A case key must not be empty.")
            }
            guard seen.insert(key).inserted else {
                throw MCPToolError.invalidArguments(
                    tool: tool, detail: "Duplicate case key \"\(key)\".")
            }
        }
    }

    /// Builds the `PatternFamily` from the input, filling parallel arrays and
    /// defaults; all per-kind / arity / ref legality is left to the validator
    /// that runs inside applySuiteEdit.
    private static func buildFamily(_ input: Input, id: String, kind: PatternKind) throws -> PatternFamily {
        let defaults = PatternDefaults(
            tier: try parseOptionalTier(input.defaultTier, tool: Self.name) ?? .pub,
            points: input.defaultPoints ?? 1,
            hint: normalizedHint(input.defaultHint),
            tolerance: input.tolerance,
            timeLimitSeconds: try normalizedTimeLimit(
                input.defaultTimeLimitSeconds, tool: Self.name, field: "defaultTimeLimitSeconds"))
        let cases = try input.cases.map { try patternCase(from: $0, tool: Self.name) }
        return PatternFamily(
            id: id, name: input.name, kind: kind, functionName: input.function ?? "",
            paramNames: input.paramNames ?? [], defaults: defaults, cases: cases,
            variables: (input.variables ?? []).map { FamilyVariable(name: $0.name, value: $0.value) },
            dependsOn: input.dependsOn ?? [])
    }

    /// Builds one `PatternCase` from a case input, filling the parallel
    /// `argsProvided` / `argVarRefs` arrays and normalising the hint and
    /// per-student ref.  Shared with update_pattern_family's `addCases` path so a
    /// new case is constructed identically however it is authored; all per-kind /
    /// arity / ref legality is left to the validator that runs inside
    /// applySuiteEdit.
    static func patternCase(from c: CaseInput, tool: String) throws -> PatternCase {
        let args = c.args ?? []
        let provided =
            try aligned(c.argsProvided, count: args.count, field: "argsProvided", key: c.key, tool: tool)
            ?? [Bool](repeating: true, count: args.count)
        let refs =
            try aligned(c.argVarRefs, count: args.count, field: "argVarRefs", key: c.key, tool: tool)
            ?? [String?](repeating: nil, count: args.count)
        let ref = c.expectedVarRef.flatMap { $0.isEmpty ? nil : $0 }
        return PatternCase(
            key: c.key, label: c.label ?? c.key, args: args, expected: c.expected ?? .null,
            argsProvided: provided, argVarRefs: refs, expectedVarRef: ref,
            hint: normalizedHint(c.hint), tier: try parseOptionalTier(c.tier, tool: tool),
            points: c.points,
            timeLimitSeconds: try normalizedTimeLimit(
                c.timeLimitSeconds, tool: tool, field: "cases[\(c.key)].timeLimitSeconds"),
            enabled: c.enabled ?? true)
    }

    /// Validates a parallel array's length against the args length, returning it
    /// (or nil when the caller omitted it).  Shared with update_pattern_family's
    /// `addCases` path, so it takes the calling tool's name for the error.
    static func aligned<T>(
        _ value: [T]?, count: Int, field: String, key: String, tool: String
    ) throws -> [T]? {
        guard let value else { return nil }
        guard value.count == count else {
            throw MCPToolError.invalidArguments(
                tool: tool,
                detail: "case '\(key)': \(field) length (\(value.count)) must match args length (\(count)).")
        }
        return value
    }

    /// Inserts the new family row immediately after the last existing item in
    /// the same section (keeping that section's block contiguous, which
    /// applyPatternFamilies requires); appends at the end when the section is
    /// empty or ungrouped.
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

    /// Trims an empty hint to nil so an omitted/blank cell doesn't store an
    /// empty "💡 Hint" callout.  Matches the empty-string handling used for
    /// per-student refs.
    static func normalizedHint(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    /// Normalizes a create-path time limit: nil/0 → nil (no override), and any
    /// non-zero value is bound-checked to `1...600` (mirroring 0 as the "clear"
    /// sentinel used on the update path). Shared by the family default and the
    /// per-case create path so a malformed value is rejected here, not shipped.
    static func normalizedTimeLimit(_ raw: Int?, tool: String, field: String) throws -> Int? {
        guard let raw, raw != 0 else { return nil }
        return try validateTimeLimitSeconds(raw, tool: tool, field: field)
    }
}
