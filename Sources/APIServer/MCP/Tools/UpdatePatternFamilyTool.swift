// APIServer/MCP/Tools/UpdatePatternFamilyTool.swift
//
// Write tool: edit a pattern family for an assignment — its default tier/points,
// which cases are enabled, and (per case) the test logic itself: `args` and
// `expected`.  content:write, course-scoped.
//
// Targeted read-modify-write through the same applySuiteEdit / applyPatternFamilies
// path the web editor uses: loads the current authored suite, reconstructs the
// family with the requested default / case-enabled / case-arg edits (every other
// field preserved verbatim), and re-saves, which regenerates the family's scripts
// AND re-runs the structural + per-kind validation (arg count vs paramNames, the
// per-kind `expected` shape, `$var` ref resolution) synchronously — so a bad edit
// is rejected here, not silently shipped.
//
// The agent sends `args` / `expected` as raw JSON values, so types are faithful
// (a string column stays a string); no client-side coercion is involved. When an
// edit replaces `args`, the parallel `argVarRefs` / `argsProvided` arrays reset to
// "all literal / all provided" unless the agent supplies them explicitly (and they
// must then align with the new args length).

import Core
import Fluent
import Foundation
import Vapor

struct UpdatePatternFamilyTool: ContentTool {
    /// A per-case edit. `key` is required; any of `args` / `expected` /
    /// `argVarRefs` / `argsProvided` may be set to replace that field.
    struct CaseEdit: Decodable, Sendable {
        let key: String
        let args: [JSONValue]?
        let expected: JSONValue?
        /// Parallel to `args`: `$name` family/section/global variable refs, or
        /// null at a position to use the literal in `args`.
        let argVarRefs: [String?]?
        /// Parallel to `args`: false at a position omits that argument so
        /// the function's own parameter default applies.
        let argsProvided: [Bool]?
        /// Per-student expected (issue #461): the name of a global/section `=`
        /// expression whose value, resolved for the student's seed at grading
        /// time, is the expected return — instead of the literal `expected`.
        /// `boundary_equality` only. An empty string clears it; setting
        /// `expected` (a literal) also clears it.
        let expectedVarRef: String?
        /// Per-case "💡 Hint" shown when this case fails (overrides the family
        /// `defaultHint`). nil leaves the existing hint untouched; an empty
        /// string clears it.
        let hint: String?
        /// Per-case execution time limit (seconds), in `1...600`. nil leaves
        /// the existing value untouched; `0` clears it (the case reverts to the
        /// family default / assignment-wide default).
        let timeLimitSeconds: Int?

        init(
            key: String, args: [JSONValue]? = nil, expected: JSONValue? = nil,
            argVarRefs: [String?]? = nil, argsProvided: [Bool]? = nil,
            expectedVarRef: String? = nil, hint: String? = nil,
            timeLimitSeconds: Int? = nil
        ) {
            self.key = key
            self.args = args
            self.expected = expected
            self.argVarRefs = argVarRefs
            self.argsProvided = argsProvided
            self.expectedVarRef = expectedVarRef
            self.hint = hint
            self.timeLimitSeconds = timeLimitSeconds
        }
    }

    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        let familyID: String
        let defaultTier: String?
        let defaultPoints: Int?
        /// Family-wide "💡 Hint" applied to cases without their own hint. nil
        /// leaves it untouched; an empty string clears it.
        let defaultHint: String?
        /// Family-level per-test execution time limit (seconds), in `1...600`,
        /// applied to every generated entry (cases + existence guard) that has
        /// no per-case override. nil leaves it untouched; `0` clears it (revert
        /// to the assignment-wide default).
        let defaultTimeLimitSeconds: Int?
        let enableCases: [String]?
        let disableCases: [String]?
        /// Per-case `args` / `expected` edits (the test logic).
        let cases: [CaseEdit]?
        /// Brand-new cases to append to the family. Each is a full case spec
        /// (the same shape create_pattern_family takes); keys must not collide
        /// with an existing case. nil/empty appends nothing — use `cases` to
        /// edit a case that already exists.
        let addCases: [CreatePatternFamilyTool.CaseInput]?
        /// Replaces the family's prerequisites (script filenames or `family:<id>`
        /// tokens). Pass `[]` to clear all prerequisites; omit (nil) to leave
        /// them untouched. Expanded + cycle-checked by the same save path the
        /// web editor uses.
        let dependsOn: [String]?
        /// Replaces the `differential` reference implementation. Omit (nil) to
        /// leave it untouched — an instructor fixing a broken reference edits it
        /// here rather than re-creating the family.
        let referenceImplementation: String?

        init(
            assignmentPublicID: String, familyID: String, defaultTier: String? = nil,
            defaultPoints: Int? = nil, defaultHint: String? = nil,
            defaultTimeLimitSeconds: Int? = nil, enableCases: [String]? = nil,
            disableCases: [String]? = nil, cases: [CaseEdit]? = nil,
            addCases: [CreatePatternFamilyTool.CaseInput]? = nil, dependsOn: [String]? = nil,
            referenceImplementation: String? = nil
        ) {
            self.assignmentPublicID = assignmentPublicID
            self.familyID = familyID
            self.defaultTier = defaultTier
            self.defaultPoints = defaultPoints
            self.defaultHint = defaultHint
            self.defaultTimeLimitSeconds = defaultTimeLimitSeconds
            self.enableCases = enableCases
            self.disableCases = disableCases
            self.cases = cases
            self.addCases = addCases
            self.dependsOn = dependsOn
            self.referenceImplementation = referenceImplementation
        }
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let familyID: String
        let defaultTier: String
        let defaultPoints: Int
        let enabledCaseKeys: [String]
        /// Keys of cases whose args/expected were edited by this call.
        let editedCaseKeys: [String]
        /// Keys of cases appended by `addCases` in this call.
        let addedCaseKeys: [String]
        let validationStatus: String?
        /// true when this edit closed a previously-open assignment (re-open with
        /// update_assignment once validation passes).
        let assignmentClosed: Bool
    }

    static let name = "update_pattern_family"
    static let description =
        "Edit a pattern family for an assignment, by assignment public ID + family id. Set the "
        + "family's default tier (\(MCPTierProse.slashAlternatives)) and/or points, enable/disable cases "
        + "by key (enableCases / disableCases), set the family-wide `defaultHint` and/or per-case "
        + "`hint` (the \"💡 Hint\" shown to the student only when that test fails; empty string clears "
        + "it), set the family-level `defaultTimeLimitSeconds` and/or a per-case `timeLimitSeconds` "
        + "(per-test execution time limit, 1–600s, overriding the assignment default; 0 clears it), "
        + "and/or edit individual cases' test logic via `cases` "
        + "(each { key, args?, expected? }). args/expected are raw JSON values (a list of args in "
        + "parameter order, and the expected return). Append brand-new cases with `addCases` (each a "
        + "full { key, args, expected, ... } spec like create_pattern_family takes; keys must not "
        + "already exist — use `cases` to edit an existing one). Replace the family's prerequisites with "
        + "`dependsOn` (script filenames or `family:<id>` tokens; pass `[]` to clear them). Saving "
        + "regenerates the family's scripts and "
        + "re-runs validation, which rejects a wrong arg count or an expected value of the wrong shape "
        + "for the family's kind. Saving also closes the assignment if it was open (re-open with "
        + "update_assignment once validation passes). Function-calling families carry an auto-generated "
        + "`<function> is defined` existence guard (0 points) that the cases depend on; it isn't a case "
        + "and you don't manage it directly. Family ids and case keys come from get_suite."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "familyID": .object([
                "type": .string("string"),
                "description": .string("The pattern family's id (from get_suite)."),
            ]),
            "defaultTier": MCPSchema.tierEnum(),
            "defaultPoints": MCPSchema.integer,
            "defaultHint": .object([
                "type": .string("string"),
                "description": .string(
                    "Family-wide \"💡 Hint\" shown on a failing case that has no per-case hint. "
                        + "Empty string clears it."),
            ]),
            "defaultTimeLimitSeconds": .object([
                "type": .string("integer"),
                "description": .string(
                    "Family-level per-test execution time limit (seconds, 1–600) for every "
                        + "generated entry without its own override. 0 clears it (revert to the "
                        + "assignment default); omit to leave unchanged."),
            ]),
            "enableCases": .object([
                "type": .string("array"), "items": MCPSchema.string,
                "description": .string("Case keys to enable."),
            ]),
            "disableCases": .object([
                "type": .string("array"), "items": MCPSchema.string,
                "description": .string("Case keys to disable."),
            ]),
            "cases": .object([
                "type": .string("array"),
                "description": .string("Per-case test-logic edits; each targets an existing case by key."),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "key": .object([
                            "type": .string("string"),
                            "description": .string("Target case key (must already exist)."),
                        ]),
                        "args": .object([
                            "type": .string("array"),
                            "description": .string("Args in parameter order (raw JSON values)."),
                        ]),
                        "expected": .object([
                            "description": .string("Expected return value (raw JSON), shape per family kind.")
                        ]),
                        "argVarRefs": .object([
                            "type": .string("array"),
                            "description": .string("Parallel to args: \"name\" for a $var ref, or null for a literal."),
                        ]),
                        "argsProvided": .object([
                            "type": .string("array"),
                            "description": .string(
                                "Parallel to args: false omits the arg, so the function's own default applies."),
                        ]),
                        "expectedVarRef": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Per-student expected: name of a global/section = expression resolved for the "
                                    + "student's seed (boundary_equality, approximate_equality, "
                                    + "unordered_equality, and variable_equality). Empty string clears it."),
                        ]),
                        "hint": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Per-case \"💡 Hint\" shown when this case fails (overrides defaultHint). "
                                    + "Empty string clears it."),
                        ]),
                        "timeLimitSeconds": .object([
                            "type": .string("integer"),
                            "description": .string(
                                "Per-case execution time limit (seconds, 1–600), overriding the family "
                                    + "default. 0 clears it; omit to leave unchanged."),
                        ]),
                    ]),
                    "required": .array([.string("key")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
            "addCases": .object([
                "type": .string("array"),
                "description": .string(
                    "New cases to append (keys must not already exist; use `cases` to edit an "
                        + "existing one)."),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "key": .object([
                            "type": .string("string"),
                            "description": .string("Unique case key (also part of the generated filename)."),
                        ]),
                        "label": MCPSchema.string,
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
                            "description": .string(
                                "Parallel to args: false omits the arg, so the function's own default applies."),
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
                        "points": MCPSchema.integer,
                        "tier": MCPSchema.tierEnum(),
                        "timeLimitSeconds": .object([
                            "type": .string("integer"),
                            "description": .string(
                                "Per-case execution time limit (seconds, 1–600), overriding the family "
                                    + "default. 0 means no override."),
                        ]),
                        "enabled": MCPSchema.boolean,
                    ]),
                    "required": .array([.string("key")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
            "dependsOn": .object([
                "type": .string("array"), "items": MCPSchema.string,
                "description": .string(
                    "Replace the family's prerequisites (script filenames or family:<id> tokens). "
                        + "Pass [] to clear them; omit to leave unchanged."),
            ]),
            "referenceImplementation": .object([
                "type": .string("string"),
                "description": .string(
                    "Replace a kind=differential family's reference implementation "
                        + "(defines ck_ref_<function>); omit to leave unchanged."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("familyID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "familyID": MCPSchema.string,
            "defaultTier": MCPSchema.string,
            "defaultPoints": MCPSchema.integer,
            "enabledCaseKeys": .object([
                "type": .string("array"), "items": MCPSchema.string,
            ]),
            "editedCaseKeys": .object([
                "type": .string("array"), "items": MCPSchema.string,
            ]),
            "addedCaseKeys": .object([
                "type": .string("array"), "items": MCPSchema.string,
            ]),
            "validationStatus": MCPSchema.string,
            "assignmentClosed": MCPSchema.boolean,
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("familyID"), .string("defaultTier"),
            .string("defaultPoints"), .string("enabledCaseKeys"), .string("editedCaseKeys"),
            .string("addedCaseKeys"), .string("assignmentClosed"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let newTier = try parseOptionalTier(input.defaultTier, tool: Self.name, field: "defaultTier")
        let enable = Set(input.enableCases ?? [])
        let disable = Set(input.disableCases ?? [])
        let caseEdits = input.cases ?? []
        let addCases = input.addCases ?? []
        guard
            newTier != nil || input.defaultPoints != nil || input.defaultHint != nil
                || input.defaultTimeLimitSeconds != nil
                || !enable.isEmpty || !disable.isEmpty || !caseEdits.isEmpty
                || !addCases.isEmpty || input.dependsOn != nil
        else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail:
                    "Specify at least one of: defaultTier, defaultPoints, defaultHint, "
                    + "defaultTimeLimitSeconds, enableCases, disableCases, cases, addCases, dependsOn.")
        }
        guard enable.isDisjoint(with: disable) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "A case key cannot be in both enableCases and disableCases.")
        }
        // Bound-check any provided time limit (0 is allowed here as the "clear"
        // sentinel; non-zero values must fall in 1...600). addCases time limits
        // are validated by patternCase(from:) on the shared create path.
        if let dtl = input.defaultTimeLimitSeconds, dtl != 0 {
            try validateTimeLimitSeconds(dtl, tool: Self.name, field: "defaultTimeLimitSeconds")
        }
        for edit in caseEdits {
            if let tl = edit.timeLimitSeconds, tl != 0 {
                try validateTimeLimitSeconds(
                    tl, tool: Self.name, field: "cases[\(edit.key)].timeLimitSeconds")
            }
        }
        let editsByKey = try Self.indexCaseEdits(caseEdits)
        try CreatePatternFamilyTool.assertUniqueCaseKeys(addCases, tool: Self.name)

        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, tool: Self.name, atLeast: .ta)

        var payload = buildSuitePayload(fromManifest: setup.manifest, zipPath: setup.zipPath)
        guard
            let idx = payload.items.firstIndex(where: {
                $0.kind == "family" && $0.family?.id == input.familyID
            }),
            let family = payload.items[idx].family
        else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "No pattern family with id \"\(input.familyID)\" in the suite.")
        }

        let caseKeys = Set(family.cases.map(\.key))
        let unknown = enable.union(disable).union(editsByKey.keys).subtracting(caseKeys)
        guard unknown.isEmpty else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "Unknown case key(s): \(unknown.sorted().joined(separator: ", ")).")
        }
        // New cases can't reuse an existing key (that would be an edit, not an
        // add); per-kind/arity legality is left to the save-time validator.
        let addKeys = Set(addCases.map { $0.key.trimmingCharacters(in: .whitespaces) })
        let collisions = addKeys.intersection(caseKeys)
        guard collisions.isEmpty else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail:
                    "addCases key(s) already exist: \(collisions.sorted().joined(separator: ", ")). "
                    + "Use `cases` to edit an existing case.")
        }
        let newCases = try addCases.map {
            try CreatePatternFamilyTool.patternCase(from: $0, tool: Self.name)
        }

        let newDefaults = PatternDefaults(
            tier: newTier ?? family.defaults.tier,
            points: input.defaultPoints ?? family.defaults.points,
            hint: Self.resolveHintEdit(input.defaultHint, existing: family.defaults.hint),
            tolerance: family.defaults.tolerance,
            timeLimitSeconds: Self.resolveTimeLimitEdit(
                input.defaultTimeLimitSeconds, existing: family.defaults.timeLimitSeconds))
        let updatedFamily = try Self.rebuild(
            family, defaults: newDefaults,
            changes: CaseChanges(
                enable: enable, disable: disable, edits: editsByKey, newCases: newCases),
            dependsOn: input.dependsOn,
            referenceImplementation: input.referenceImplementation)
        payload.items[idx].family = updatedFamily
        // The family's row-level dependsOn wins over `family.dependsOn` in
        // applySuiteEdit, so when the caller replaces deps, mirror the new value
        // onto the row too — otherwise the stale row value would override the
        // family spec on save.
        if let newDeps = input.dependsOn {
            payload.items[idx].dependsOn = newDeps
        }

        // applySuiteEdit -> applyPatternFamilies -> validatePatternFamilies runs
        // the structural + per-kind case checks synchronously; surface those as
        // clean MCP errors rather than opaque protocol failures.
        try await applySuiteEditMapped(setup: setup, body: payload, tool: Self.name, on: context.db)
        // Close, re-grade, and re-validate (matching the web Save button).
        let finalized = try await finalizeContentEdit(
            assignment: assignment, setup: setup, context: context, retest: true)

        return Output(
            assignmentPublicID: assignment.publicID,
            familyID: updatedFamily.id,
            defaultTier: updatedFamily.defaults.tier.rawValue,
            defaultPoints: updatedFamily.defaults.points,
            enabledCaseKeys: updatedFamily.cases.filter(\.enabled).map(\.key),
            editedCaseKeys: editsByKey.keys.sorted(),
            addedCaseKeys: newCases.map(\.key),
            validationStatus: assignment.validationStatus,
            assignmentClosed: finalized.assignmentClosed)
    }

    /// Indexes case edits by key, rejecting duplicates so the last-write-wins
    /// ambiguity never reaches the rebuild.
    private static func indexCaseEdits(_ edits: [CaseEdit]) throws -> [String: CaseEdit] {
        var byKey: [String: CaseEdit] = [:]
        for edit in edits {
            guard byKey.updateValue(edit, forKey: edit.key) == nil else {
                throw MCPToolError.invalidArguments(
                    tool: name, detail: "Duplicate case edit for key \"\(edit.key)\".")
            }
        }
        return byKey
    }

    /// The case-level changes a rebuild applies: which existing cases to
    /// enable/disable, per-case arg/expected/hint edits, and brand-new cases to
    /// append.  Grouped so `rebuild` stays within the parameter-count budget.
    private struct CaseChanges {
        let enable: Set<String>
        let disable: Set<String>
        let edits: [String: CaseEdit]
        let newCases: [PatternCase]
    }

    /// Reconstructs the family with the resolved `defaults` and `changes`
    /// (enable/disable flags, per-case arg/expected/hint edits, and any new
    /// cases appended after the existing ones), with `dependsOn` replaced when
    /// provided (nil keeps the existing prerequisites); every other field is
    /// copied verbatim.
    private static func rebuild(
        _ family: PatternFamily, defaults: PatternDefaults,
        changes: CaseChanges, dependsOn: [String]?, referenceImplementation: String?
    ) throws -> PatternFamily {
        let cases = try family.cases.map { caseSpec -> PatternCase in
            let enabled =
                changes.enable.contains(caseSpec.key)
                ? true : (changes.disable.contains(caseSpec.key) ? false : caseSpec.enabled)
            return try applyCaseEdit(changes.edits[caseSpec.key], to: caseSpec, enabled: enabled)
        }
        return PatternFamily(
            id: family.id, name: family.name, kind: family.kind, functionName: family.functionName,
            paramNames: family.paramNames, defaults: defaults, cases: cases + changes.newCases,
            variables: family.variables, dependsOn: dependsOn ?? family.dependsOn,
            referenceImplementation: referenceImplementation ?? family.referenceImplementation)
    }

    /// Applies one case's arg/expected edit, keeping the parallel
    /// `argVarRefs` / `argsProvided` arrays aligned with the resolved args.
    private static func applyCaseEdit(
        _ edit: CaseEdit?, to caseSpec: PatternCase, enabled: Bool
    ) throws -> PatternCase {
        guard let edit else {
            return caseSpec.with(enabled: enabled)
        }
        let finalArgs = edit.args ?? caseSpec.args
        let finalExpected = edit.expected ?? caseSpec.expected
        let finalVarRefs = try resolveParallel(
            explicit: edit.argVarRefs, argsReplaced: edit.args != nil,
            existing: caseSpec.argVarRefs, argCount: finalArgs.count,
            field: "argVarRefs", caseKey: caseSpec.key)
        let finalProvided = try resolveParallel(
            explicit: edit.argsProvided, argsReplaced: edit.args != nil,
            existing: caseSpec.argsProvided, argCount: finalArgs.count,
            field: "argsProvided", caseKey: caseSpec.key)
        // Per-student expected ref: an explicit edit wins (empty string clears);
        // switching to a literal `expected` clears any stale ref; otherwise the
        // existing ref carries over.
        let finalExpectedVarRef: String?
        if let ref = edit.expectedVarRef {
            finalExpectedVarRef = ref.isEmpty ? nil : ref
        } else if edit.expected != nil {
            finalExpectedVarRef = nil
        } else {
            finalExpectedVarRef = caseSpec.expectedVarRef
        }
        return PatternCase(
            key: caseSpec.key, label: caseSpec.label, args: finalArgs, expected: finalExpected,
            argsProvided: finalProvided, argVarRefs: finalVarRefs, expectedVarRef: finalExpectedVarRef,
            hint: resolveHintEdit(edit.hint, existing: caseSpec.hint),
            tier: caseSpec.tier, points: caseSpec.points,
            timeLimitSeconds: resolveTimeLimitEdit(edit.timeLimitSeconds, existing: caseSpec.timeLimitSeconds),
            enabled: enabled)
    }

    /// Resolves a hint edit against the existing value, matching the
    /// `expectedVarRef` convention: nil (omitted) preserves the existing hint,
    /// an empty string clears it, and any other string sets it.
    private static func resolveHintEdit(_ edit: String?, existing: String?) -> String? {
        guard let edit else { return existing }
        return edit.isEmpty ? nil : edit
    }

    /// Resolves a time-limit edit against the existing value, mirroring the
    /// hint convention with `0` as the sentinel for "clear": nil (omitted)
    /// preserves the existing override, `0` clears it (revert to inherit), and
    /// any other value sets it. Provided values are bound-checked by the caller
    /// (`validateTimeLimitSeconds`) before this runs, so an out-of-range value
    /// never reaches here.
    private static func resolveTimeLimitEdit(_ edit: Int?, existing: Int?) -> Int? {
        guard let edit else { return existing }
        return edit == 0 ? nil : edit
    }

    /// Resolves a parallel array (argVarRefs / argsProvided) for an edited case:
    /// an explicit value wins (and must align with the new args length); when
    /// the args were replaced the parallel array resets to empty so it can't
    /// reference stale positions; otherwise the existing value carries over.
    private static func resolveParallel<T>(
        explicit: [T]?, argsReplaced: Bool, existing: [T],
        argCount: Int, field: String, caseKey: String
    ) throws -> [T] {
        if let explicit {
            guard explicit.count == argCount else {
                throw MCPToolError.invalidArguments(
                    tool: name,
                    detail:
                        "case '\(caseKey)': \(field) length (\(explicit.count)) must match args length (\(argCount)).")
            }
            return explicit
        }
        // args replaced → reset (stale positions can't carry over); else keep.
        return argsReplaced ? [] : existing
    }

}

extension PatternCase {
    /// Copy with a new `enabled` flag; every other field preserved.
    fileprivate func with(enabled: Bool) -> PatternCase {
        PatternCase(
            key: key, label: label, args: args, expected: expected,
            argsProvided: argsProvided, argVarRefs: argVarRefs, expectedVarRef: expectedVarRef,
            hint: hint, tier: tier, points: points, timeLimitSeconds: timeLimitSeconds,
            enabled: enabled)
    }
}
