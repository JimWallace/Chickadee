// APIServer/Services/GlobalInputsService.swift
//
// HTTP-free core for an assignment's global inputs (Slice 1 literal
// `variables` + Slice 2 per-student `expressions`).  Extracted from
// `PublishedAssignmentRoutes+GlobalVariables.swift` so the web PUT handler
// and the MCP `update_global_inputs` tool drive the *same* validation +
// persistence path — they cannot drift.
//
// `apply` runs the full validation gauntlet (identifier-shape names, the
// reserved `seed` name, cross-list + cross-section uniqueness, the starter
// notebook `{{undeclared}}` scan, and a save-time eval against the acting
// user's own seed), then re-renders the setup through `applyPatternFamilies`
// so generated tests + raw scripts pick up the new literal values.  It throws
// `WebAssignmentError` on validation failure; each surface maps that to its
// own error type (the web layer renders the HTTP status directly; MCP tools
// translate to `MCPToolError`).

import Core
import Fluent
import Foundation

enum GlobalInputsService {

    /// Names that can never be declared as a global input — `seed` is bound by
    /// Chickadee's personalization layer.
    static let reservedNames: Set<String> = ["seed"]

    struct Result: Sendable {
        let variables: [FamilyVariable]
        let expressions: [PersonalizationExpression]
        let warnings: [String]
    }

    /// The two kinds of global input, bundled so the apply/eval entry points
    /// stay within the parameter-count budget.
    struct Inputs: Sendable {
        let variables: [FamilyVariable]
        let expressions: [PersonalizationExpression]
    }

    /// The currently-persisted global inputs for a setup (no validation).
    static func current(setup: APITestSetup) throws -> Result {
        let manifest = try decoded(setup)
        return Result(
            variables: manifest.globalVariables,
            expressions: manifest.globalExpressions,
            warnings: [])
    }

    /// Validate + persist a replacement set of global inputs.
    ///
    /// - `actingUserID`: the instructor/agent making the change; used to fetch
    ///   the save-time eval seed.  When nil (no eval seed available) the
    ///   save-time expression check is skipped — names + placeholder validation
    ///   still run.
    /// - `testSetupsDirectory`: the app's test-setups root, used to resolve the
    ///   per-setup `shared/<id>/` support-files directory for expression eval.
    static func apply(
        setup: APITestSetup,
        assignment: APIAssignment,
        actingUserID: UUID?,
        inputs: Inputs,
        testSetupsDirectory: String,
        on db: any Database
    ) async throws -> Result {
        let manifest = try decoded(setup)

        // 1. Per-row validation across variables + expressions.
        let seenNames = try validateNames(
            variables: inputs.variables, expressions: inputs.expressions)
        // 2. Cross-list: no clash with any section variable name.
        try validateAgainstSections(seenNames: seenNames, manifest: manifest)
        // 3. Starter-notebook `{{undeclared}}` scan.
        try validateStarterNotebookPlaceholders(seenNames: seenNames, manifest: manifest, setup: setup)
        // 4. Save-time eval check against the acting user's own seed.
        try await evaluateForActingSeed(
            actingUserID: actingUserID,
            assignment: assignment,
            manifest: manifest,
            inputs: inputs,
            testSetupsDirectory: testSetupsDirectory,
            on: db)

        // 5. Re-render through `applyPatternFamilies` so generated tests and raw
        // scripts pick up the new literal values.  Expressions flow through
        // unchanged — they only affect notebook substitution at first-open.
        _ = try await applyPatternFamilies(
            to: setup,
            nextFamilies: manifest.patternFamilies,
            nextChecks: manifest.notebookChecks,
            authoredItems: nil,
            sections: manifest.sections,
            globalVariables: inputs.variables,
            globalExpressions: inputs.expressions,
            on: db)

        // 6. Re-load the persisted manifest so the response reflects reconciled state.
        return try current(setup: setup)
    }

    // MARK: - Validation

    /// Both kinds share the same namespace at inline / substitution time, so
    /// duplicates across kinds are also rejected.
    static func validateNames(
        variables: [FamilyVariable],
        expressions: [PersonalizationExpression]
    ) throws -> Set<String> {
        var seenNames: Set<String> = []
        for v in variables {
            guard isValidPythonIdentifier(v.name) else {
                throw WebAssignmentError.unprocessable(
                    reason: "Global variable name '\(v.name)' is not a valid Python identifier.")
            }
            guard !reservedNames.contains(v.name) else {
                throw WebAssignmentError.unprocessable(
                    reason: "'\(v.name)' is reserved for Chickadee's personalization seed. " + "Choose another name.")
            }
            guard seenNames.insert(v.name).inserted else {
                throw WebAssignmentError.unprocessable(
                    reason: "Duplicate global input name '\(v.name)'.")
            }
        }
        for e in expressions {
            guard isValidPythonIdentifier(e.name) else {
                throw WebAssignmentError.unprocessable(
                    reason: "Global expression name '\(e.name)' is not a valid Python identifier.")
            }
            guard !reservedNames.contains(e.name) else {
                throw WebAssignmentError.unprocessable(
                    reason: "'\(e.name)' is reserved for Chickadee's personalization seed. " + "Choose another name.")
            }
            let trimmed = e.expression.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw WebAssignmentError.unprocessable(
                    reason: "Global expression '\(e.name)' has an empty body. "
                        + "Provide a Python expression after the leading `=` (e.g. `= seed % 26`).")
            }
            guard seenNames.insert(e.name).inserted else {
                throw WebAssignmentError.unprocessable(
                    reason: "Duplicate global input name '\(e.name)'. "
                        + "Names must be unique across literal values and expressions.")
            }
        }
        return seenNames
    }

    static func validateAgainstSections(seenNames: Set<String>, manifest: TestProperties) throws {
        for section in manifest.sections {
            for sv in section.variables {
                guard !seenNames.contains(sv.name) else {
                    throw WebAssignmentError.unprocessable(
                        reason: "Global input name '\(sv.name)' is already used by "
                            + "section '\(section.name)'. Section and global names share a "
                            + "namespace; rename one to avoid shadowing.")
                }
            }
        }
    }

    static func validateStarterNotebookPlaceholders(
        seenNames: Set<String>,
        manifest: TestProperties,
        setup: APITestSetup
    ) throws {
        var declared: Set<String> = seenNames
        for section in manifest.sections {
            for sv in section.variables { declared.insert(sv.name) }
        }
        guard let starterName = manifest.starterNotebook,
            let notebookData = extractZipEntry(zipPath: setup.zipPath, entryName: starterName)
        else { return }
        let used = NotebookSubstitution.placeholderNames(in: notebookData)
        let unknown = used.filter { !declared.contains($0) }
        guard !unknown.isEmpty else { return }
        let list = unknown.map { "{{\($0)}}" }.joined(separator: ", ")
        throw WebAssignmentError.unprocessable(
            reason: "Starter notebook references unknown placeholder(s): \(list). "
                + "Declare them as global or section inputs first.")
    }

    /// Runs every expression against the acting user's own seed.  Any syntax
    /// error / runtime exception surfaces here so typos don't reach students.
    /// Skipped when no expressions were declared, or no acting seed is
    /// available.
    static func evaluateForActingSeed(
        actingUserID: UUID?,
        assignment: APIAssignment,
        manifest: TestProperties,
        inputs: Inputs,
        testSetupsDirectory: String,
        on db: any Database
    ) async throws {
        guard !inputs.expressions.isEmpty,
            let userID = actingUserID,
            let assignmentID = assignment.id
        else { return }
        let seedHex = try await AssignmentSeedStore.ensureSeed(
            userID: userID, assignmentID: assignmentID, on: db)
        // Combine globals + section vars so expressions can reference the same
        // static names they would at student first-open.
        var staticVars: [FamilyVariable] = inputs.variables
        for section in manifest.sections {
            staticVars.append(contentsOf: section.variables)
        }
        do {
            _ = try await PersonalizationEvaluator.evaluate(
                seedHex: seedHex,
                staticVariables: staticVars,
                expressions: inputs.expressions,
                supportFilesDirectory: testSetupsDirectory + "shared/\(assignment.testSetupID)/")
        } catch let PersonalizationEvaluatorError.nonZeroExit(_, stderr) {
            let tail = stderr.split(separator: "\n").suffix(3).joined(separator: " ")
            throw WebAssignmentError.unprocessable(
                reason: "One of your expressions failed to evaluate: \(tail). "
                    + "Fix the expression(s) and save again.")
        } catch PersonalizationEvaluatorError.timedOut {
            throw WebAssignmentError.unprocessable(
                reason: "Expression evaluation timed out (>5s). "
                    + "Simplify the expressions or move heavy lifting into a support module.")
        } catch {
            throw WebAssignmentError.internalFailure(reason: "Expression evaluator failed: \(error)")
        }
    }

    // MARK: - helpers

    private static func decoded(_ setup: APITestSetup) throws -> TestProperties {
        guard let manifest = setup.decodedManifest() else {
            throw WebAssignmentError.internalFailure(reason: "Manifest is not valid JSON.")
        }
        return manifest
    }
}
