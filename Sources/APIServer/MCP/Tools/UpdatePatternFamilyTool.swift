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
        /// Python's own parameter default applies.
        let argsProvided: [Bool]?

        init(
            key: String, args: [JSONValue]? = nil, expected: JSONValue? = nil,
            argVarRefs: [String?]? = nil, argsProvided: [Bool]? = nil
        ) {
            self.key = key
            self.args = args
            self.expected = expected
            self.argVarRefs = argVarRefs
            self.argsProvided = argsProvided
        }
    }

    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        let familyID: String
        let defaultTier: String?
        let defaultPoints: Int?
        let enableCases: [String]?
        let disableCases: [String]?
        /// Per-case `args` / `expected` edits (the test logic).
        let cases: [CaseEdit]?

        init(
            assignmentPublicID: String, familyID: String, defaultTier: String? = nil,
            defaultPoints: Int? = nil, enableCases: [String]? = nil, disableCases: [String]? = nil,
            cases: [CaseEdit]? = nil
        ) {
            self.assignmentPublicID = assignmentPublicID
            self.familyID = familyID
            self.defaultTier = defaultTier
            self.defaultPoints = defaultPoints
            self.enableCases = enableCases
            self.disableCases = disableCases
            self.cases = cases
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
        let validationStatus: String?
    }

    static let name = "update_pattern_family"
    static let description =
        "Edit a pattern family for an assignment, by assignment public ID + family id. Set the "
        + "family's default tier (public/release/secret/student) and/or points, enable/disable cases "
        + "by key (enableCases / disableCases), and/or edit individual cases' test logic via `cases` "
        + "(each { key, args?, expected? }). args/expected are raw JSON values (a list of args in "
        + "parameter order, and the expected return). Saving regenerates the family's scripts and "
        + "re-runs validation, which rejects a wrong arg count or an expected value of the wrong shape "
        + "for the family's kind. Family ids and case keys come from get_suite."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "familyID": .object([
                "type": .string("string"),
                "description": .string("The pattern family's id (from get_suite)."),
            ]),
            "defaultTier": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("public"), .string("release"), .string("secret"), .string("student"),
                ]),
            ]),
            "defaultPoints": .object(["type": .string("integer")]),
            "enableCases": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
                "description": .string("Case keys to enable."),
            ]),
            "disableCases": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
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
                            "description": .string("Parallel to args: false omits the arg (use Python default)."),
                        ]),
                    ]),
                    "required": .array([.string("key")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("familyID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object(["type": .string("string")]),
            "familyID": .object(["type": .string("string")]),
            "defaultTier": .object(["type": .string("string")]),
            "defaultPoints": .object(["type": .string("integer")]),
            "enabledCaseKeys": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
            ]),
            "editedCaseKeys": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
            ]),
            "validationStatus": .object(["type": .string("string")]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("familyID"), .string("defaultTier"),
            .string("defaultPoints"), .string("enabledCaseKeys"), .string("editedCaseKeys"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let newTier = try Self.parseTier(input.defaultTier)
        let enable = Set(input.enableCases ?? [])
        let disable = Set(input.disableCases ?? [])
        let caseEdits = input.cases ?? []
        guard
            newTier != nil || input.defaultPoints != nil || !enable.isEmpty || !disable.isEmpty
                || !caseEdits.isEmpty
        else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "Specify at least one of: defaultTier, defaultPoints, enableCases, disableCases, cases.")
        }
        guard enable.isDisjoint(with: disable) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "A case key cannot be in both enableCases and disableCases.")
        }
        let editsByKey = try Self.indexCaseEdits(caseEdits)

        guard let assignment = try await assignmentByPublicID(input.assignmentPublicID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "No assignment found with public ID \"\(input.assignmentPublicID)\".")
        }
        try await context.authorizeCourseAccess(assignment.courseID, tool: Self.name)
        guard let setup = try await APITestSetup.find(assignment.testSetupID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "The assignment's test setup could not be found.")
        }

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

        let updatedFamily = try Self.rebuild(
            family, newTier: newTier, newPoints: input.defaultPoints,
            enable: enable, disable: disable, edits: editsByKey)
        payload.items[idx].family = updatedFamily

        // applySuiteEdit -> applyPatternFamilies -> validatePatternFamilies runs
        // the structural + per-kind case checks synchronously; surface those as
        // clean MCP errors rather than opaque protocol failures.
        do {
            try await applySuiteEdit(setup: setup, body: payload, on: context.db)
        } catch let error as WebAssignmentError {
            throw MCPToolError.from(error, tool: Self.name)
        } catch let error as any AbortError {
            throw MCPToolError.from(error, tool: Self.name)
        }
        await scheduleValidationAfterSuiteEdit(req: context.request, assignment: assignment)

        return Output(
            assignmentPublicID: assignment.publicID,
            familyID: updatedFamily.id,
            defaultTier: updatedFamily.defaults.tier.rawValue,
            defaultPoints: updatedFamily.defaults.points,
            enabledCaseKeys: updatedFamily.cases.filter(\.enabled).map(\.key),
            editedCaseKeys: editsByKey.keys.sorted(),
            validationStatus: assignment.validationStatus)
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

    /// Reconstructs the family with new defaults, per-case enabled flags, and
    /// per-case arg/expected edits; every other field is copied verbatim.
    private static func rebuild(
        _ family: PatternFamily, newTier: TestTier?, newPoints: Int?,
        enable: Set<String>, disable: Set<String>, edits: [String: CaseEdit]
    ) throws -> PatternFamily {
        let defaults = PatternDefaults(
            tier: newTier ?? family.defaults.tier,
            points: newPoints ?? family.defaults.points,
            hint: family.defaults.hint,
            tolerance: family.defaults.tolerance)
        let cases = try family.cases.map { caseSpec -> PatternCase in
            let enabled =
                enable.contains(caseSpec.key)
                ? true : (disable.contains(caseSpec.key) ? false : caseSpec.enabled)
            return try applyCaseEdit(edits[caseSpec.key], to: caseSpec, enabled: enabled)
        }
        return PatternFamily(
            id: family.id, name: family.name, kind: family.kind, functionName: family.functionName,
            paramNames: family.paramNames, defaults: defaults, cases: cases,
            variables: family.variables, dependsOn: family.dependsOn)
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
        return PatternCase(
            key: caseSpec.key, label: caseSpec.label, args: finalArgs, expected: finalExpected,
            argsProvided: finalProvided, argVarRefs: finalVarRefs, hint: caseSpec.hint,
            tier: caseSpec.tier, points: caseSpec.points, enabled: enabled)
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

    private static func parseTier(_ raw: String?) throws -> TestTier? {
        guard let raw else { return nil }
        guard let tier = TestTier(rawValue: raw) else {
            throw MCPToolError.invalidArguments(
                tool: name, detail: "defaultTier must be one of: public, release, secret, student.")
        }
        return tier
    }
}

extension PatternCase {
    /// Copy with a new `enabled` flag; every other field preserved.
    fileprivate func with(enabled: Bool) -> PatternCase {
        PatternCase(
            key: key, label: label, args: args, expected: expected,
            argsProvided: argsProvided, argVarRefs: argVarRefs, hint: hint,
            tier: tier, points: points, enabled: enabled)
    }
}
