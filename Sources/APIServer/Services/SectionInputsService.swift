// APIServer/Services/SectionInputsService.swift
//
// HTTP-free core for a test-suite section's personalization inputs — the
// section-scoped literal `variables` and per-student `expressions`.  Extracted
// from `PublishedAssignmentRoutes+SuiteSections.swift` so the web POST handler
// and the MCP `update_section_variables` tool drive the *same* validation +
// persistence path.
//
// `apply` runs the section validation gauntlet (identifier-shape names, the
// reserved `seed` name, uniqueness within the section, no clash with globals or
// any OTHER section, and a save-time eval against the acting account's own
// seed), then persists the section's variables/expressions onto the manifest.
// Unlike global inputs it does NOT re-render through `applyPatternFamilies`:
// section variables are read at generation/first-open time from the manifest,
// and the web handler likewise only mutates `manifest.sections`.

import Core
import Fluent
import Foundation

enum SectionInputsService {

    /// The two kinds of section input, bundled to keep the entry points within
    /// the parameter-count budget.
    struct Inputs: Sendable {
        let variables: [FamilyVariable]
        let expressions: [PersonalizationExpression]
    }

    /// Non-HTTP context for the save-time expression eval.
    struct SeedContext: Sendable {
        let actingUserID: UUID?
        let assignmentID: UUID?
        /// The test setup id, used to resolve the per-setup `shared/<id>/`
        /// support-files directory.
        let testSetupID: String
        /// The app's test-setups root.
        let testSetupsDirectory: String
    }

    /// The persisted inputs for one section (no validation).  Returns nil when
    /// no section with `sectionID` exists.
    static func current(setup: APITestSetup, sectionID: String) throws -> Inputs? {
        guard let manifest = setup.decodedManifest() else {
            throw WebAssignmentError.internalFailure(reason: "Manifest is not valid JSON.")
        }
        guard let section = manifest.sections.first(where: { $0.id == sectionID }) else { return nil }
        return Inputs(variables: section.variables, expressions: section.expressions)
    }

    /// Validate + persist a replacement set of inputs for one section.
    static func apply(
        setup: APITestSetup,
        sectionID: String,
        inputs: Inputs,
        seed: SeedContext,
        on db: any Database
    ) async throws {
        guard let manifest = setup.decodedManifest() else {
            throw WebAssignmentError.internalFailure(reason: "Manifest is not valid JSON.")
        }

        // 1. Per-row validation across this section's vars + expressions.
        let seenNames = try validateNames(variables: inputs.variables, expressions: inputs.expressions)
        // 2. Cross-section + global clash check.
        try validateAgainstOtherScopes(seenNames: seenNames, manifest: manifest, sectionID: sectionID)
        // 3. Save-time eval check against the acting account's own seed.
        try await evaluateForActingSeed(
            manifest: manifest, sectionID: sectionID, inputs: inputs, seed: seed, on: db)
        // 4. Persist onto the manifest's section list.
        try await persist(setup: setup, sectionID: sectionID, inputs: inputs, on: db)
    }

    // MARK: - Validation

    /// Validates that every variable/expression name is a valid Python
    /// identifier, not the reserved `seed`, and unique across both kinds.
    static func validateNames(
        variables: [FamilyVariable],
        expressions: [PersonalizationExpression]
    ) throws -> Set<String> {
        var seenNames: Set<String> = []
        for v in variables {
            guard isValidPythonIdentifier(v.name) else {
                throw WebAssignmentError.unprocessable(
                    reason: "Section input name '\(v.name)' is not a valid Python identifier.")
            }
            guard v.name != "seed" else {
                throw WebAssignmentError.unprocessable(
                    reason: "'seed' is reserved for Chickadee's personalization seed.")
            }
            guard seenNames.insert(v.name).inserted else {
                throw WebAssignmentError.unprocessable(
                    reason: "Duplicate section input name '\(v.name)'.")
            }
        }
        for e in expressions {
            guard isValidPythonIdentifier(e.name) else {
                throw WebAssignmentError.unprocessable(
                    reason: "Section expression name '\(e.name)' is not a valid Python identifier.")
            }
            guard e.name != "seed" else {
                throw WebAssignmentError.unprocessable(
                    reason: "'seed' is reserved for Chickadee's personalization seed.")
            }
            let trimmed = e.expression.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw WebAssignmentError.unprocessable(
                    reason: "Section expression '\(e.name)' has an empty body. "
                        + "Provide a Python expression after the leading `=`.")
            }
            guard seenNames.insert(e.name).inserted else {
                throw WebAssignmentError.unprocessable(
                    reason: "Duplicate section input name '\(e.name)'. "
                        + "Names must be unique across literal values and expressions.")
            }
        }
        return seenNames
    }

    /// Cross-section + global clash: no name in this section's combined
    /// namespace may collide with a name in `globalVariables`,
    /// `globalExpressions`, or any OTHER section's variables/expressions.
    static func validateAgainstOtherScopes(
        seenNames: Set<String>,
        manifest: TestProperties,
        sectionID: String
    ) throws {
        var otherNames: Set<String> = []
        for v in manifest.globalVariables { otherNames.insert(v.name) }
        for e in manifest.globalExpressions { otherNames.insert(e.name) }
        for section in manifest.sections where section.id != sectionID {
            for v in section.variables { otherNames.insert(v.name) }
            for e in section.expressions { otherNames.insert(e.name) }
        }
        for n in seenNames where otherNames.contains(n) {
            throw WebAssignmentError.unprocessable(
                reason: "Section input '\(n)' is already used by a global input or another section. "
                    + "Names share one namespace across the assignment; rename to avoid shadowing.")
        }
    }

    /// Runs every expression once against the acting account's own seed so
    /// typos surface before students hit them.  No-op when there are no
    /// expressions or no acting seed.
    static func evaluateForActingSeed(
        manifest: TestProperties,
        sectionID: String,
        inputs: Inputs,
        seed: SeedContext,
        on db: any Database
    ) async throws {
        guard !inputs.expressions.isEmpty,
            let userID = seed.actingUserID,
            let assignmentID = seed.assignmentID
        else { return }

        let seedHex = try await AssignmentSeedStore.ensureSeed(
            userID: userID, assignmentID: assignmentID, on: db)
        // Combine globals + this section's new vars + other sections' vars
        // (matches the runtime scope the evaluator uses at first-open).
        var staticVars: [FamilyVariable] = manifest.globalVariables
        staticVars.append(contentsOf: inputs.variables)
        for section in manifest.sections where section.id != sectionID {
            staticVars.append(contentsOf: section.variables)
        }
        let supportDir = seed.testSetupsDirectory + "shared/\(seed.testSetupID)/"
        do {
            _ = try await PersonalizationEvaluator.evaluate(
                seedHex: seedHex,
                staticVariables: staticVars,
                expressions: inputs.expressions,
                supportFilesDirectory: supportDir)
        } catch let PersonalizationEvaluatorError.nonZeroExit(_, stderr) {
            let tail = stderr.split(separator: "\n").suffix(3).joined(separator: " ")
            throw WebAssignmentError.unprocessable(
                reason: "One of your section expressions failed to evaluate: \(tail). "
                    + "Fix the expression(s) and save again.")
        } catch PersonalizationEvaluatorError.timedOut {
            throw WebAssignmentError.unprocessable(
                reason: "Expression evaluation timed out (>5s). "
                    + "Simplify the expressions or move heavy lifting into a support module.")
        } catch {
            throw WebAssignmentError.internalFailure(reason: "Expression evaluator failed: \(error)")
        }
    }

    // MARK: - Persistence

    static func persist(
        setup: APITestSetup,
        sectionID: String,
        inputs: Inputs,
        on db: any Database
    ) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let varData = try encoder.encode(inputs.variables)
        let exprData = try encoder.encode(inputs.expressions)
        guard let parsedVars = try JSONSerialization.jsonObject(with: varData) as? [Any],
            let parsedExprs = try JSONSerialization.jsonObject(with: exprData) as? [Any]
        else {
            throw WebAssignmentError.internalFailure(reason: "Failed to re-serialise section inputs.")
        }

        try await mutateManifest(setup: setup, on: db) { dict in
            guard var sections = dict["sections"] as? [[String: Any]] else {
                throw WebAssignmentError.notFound(resource: "Section '\(sectionID)'")
            }
            guard let idx = sections.firstIndex(where: { ($0["id"] as? String) == sectionID }) else {
                throw WebAssignmentError.notFound(resource: "Section '\(sectionID)'")
            }
            if parsedVars.isEmpty {
                sections[idx].removeValue(forKey: "variables")
            } else {
                sections[idx]["variables"] = parsedVars
            }
            if parsedExprs.isEmpty {
                sections[idx].removeValue(forKey: "expressions")
            } else {
                sections[idx]["expressions"] = parsedExprs
            }
            dict["sections"] = sections
        }
    }
}
