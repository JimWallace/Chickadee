// APIServer/Routes/Web/AssignmentRoutes+GlobalVariables.swift
//
// Slice 1 + Slice 2 — assignment-scope global inputs.
// GET returns the current variables + expressions; PUT replaces both
// atomically and re-renders the test setup via applyPatternFamilies.
//
// Two row kinds:
//   - `variables` (Slice 1): literal values, inlined at save time into
//     pattern-family-generated scripts and raw Python test scripts, and
//     substituted into the starter notebook at student first-open.
//   - `expressions` (Slice 2): Python source evaluated per-student at
//     notebook first-open with `seed` and every static variable in
//     scope.  Expression results substitute into the starter notebook
//     alongside literal values.  They do NOT reach test scripts in this
//     slice — test scripts continue using the v0.4.156 env-var seed
//     contract for any per-student logic.
//
// Validation (run at PUT time):
//   - identifier-shape names;
//   - `seed` reserved across both kinds;
//   - no duplicates within variables, within expressions, OR across
//     (single Python namespace);
//   - no clash with any section variable;
//   - every `{{name}}` marker in the starter notebook matches a
//     declared name (across variables + expressions + section vars);
//   - a save-time eval against the instructor's own seed catches
//     syntactically-broken expressions (`1/0`, `import nonexistent`,
//     etc.) before students hit them.
//
// On success: 200 OK + JSON body with the reconciled lists and any
// non-blocking warnings.

import Core
import Fluent
import Foundation
import Vapor

extension AssignmentRoutes {

    private static let reservedGlobalNames: Set<String> = ["seed"]

    struct GlobalVariablesBody: Content {
        var variables: [FamilyVariable]
        /// Slice 2 — optional in the request body so older editor builds
        /// keep working (they don't send the field; server treats as []).
        var expressions: [PersonalizationExpression]?
    }

    struct GlobalVariablesResponse: Content {
        var variables: [FamilyVariable]
        var expressions: [PersonalizationExpression]
        var warnings: [String]
    }

    // MARK: - GET /instructor/:assignmentID/global-variables

    @Sendable
    func getGlobalVariables(req: Request) async throws -> GlobalVariablesResponse {
        try requireInstructor(req)
        let (_, setup) = try await loadAssignmentAndSetup(req)

        let manifest = try decodeManifest(setup: setup)
        return GlobalVariablesResponse(
            variables: manifest.globalVariables,
            expressions: manifest.globalExpressions,
            warnings: []
        )
    }

    // MARK: - PUT /instructor/:assignmentID/global-variables

    @Sendable
    func putGlobalVariables(req: Request) async throws -> GlobalVariablesResponse {
        try requireInstructor(req)
        let (assignment, setup) = try await loadAssignmentAndSetup(req)
        let body = try req.content.decode(GlobalVariablesBody.self)
        let expressions = body.expressions ?? []

        let manifest = try decodeManifest(setup: setup)

        // 1. Per-row validation across variables + expressions.  Both
        // kinds share the same namespace at inline / substitution time,
        // so duplicates across kinds are also rejected.
        var seenNames: Set<String> = []

        for v in body.variables {
            guard isValidPythonIdentifier(v.name) else {
                throw WebAssignmentError.unprocessable(
                    reason: "Global variable name '\(v.name)' is not a valid Python identifier.")
            }
            guard !Self.reservedGlobalNames.contains(v.name) else {
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
            guard !Self.reservedGlobalNames.contains(e.name) else {
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

        // 2. Cross-list: no clash with any section variable name.
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

        // 3. Starter-notebook `{{undeclared}}` scan.
        var declared: Set<String> = seenNames
        for section in manifest.sections {
            for sv in section.variables { declared.insert(sv.name) }
        }
        if let starterName = manifest.starterNotebook,
            let notebookData = extractZipEntry(
                zipPath: setup.zipPath,
                entryName: starterName)
        {
            let used = NotebookSubstitution.placeholderNames(in: notebookData)
            let unknown = used.filter { !declared.contains($0) }
            if !unknown.isEmpty {
                let list = unknown.map { "{{\($0)}}" }.joined(separator: ", ")
                throw WebAssignmentError.unprocessable(
                    reason: "Starter notebook references unknown placeholder(s): \(list). "
                        + "Declare them as global or section inputs first.")
            }
        }

        // 4. Save-time eval check: run every expression against the
        // INSTRUCTOR's own seed.  Any syntax error / runtime exception
        // surfaces here as a 400 with the offending expression's name,
        // so typos don't reach students.  Skipped when no expressions
        // were declared (most common case).
        if !expressions.isEmpty, let userID = (try req.auth.require(APIUser.self)).id,
            let assignmentID = assignment.id
        {
            let seedHex = try await AssignmentSeedStore.ensureSeed(
                userID: userID,
                assignmentID: assignmentID,
                on: req.db
            )
            // Combine globals + section vars so expressions can reference
            // the same static names they would at student first-open.
            var staticVars: [FamilyVariable] = body.variables
            for section in manifest.sections {
                staticVars.append(contentsOf: section.variables)
            }
            do {
                _ = try await PersonalizationEvaluator.evaluate(
                    seedHex: seedHex,
                    staticVariables: staticVars,
                    expressions: expressions,
                    supportFilesDirectory: req.application.testSetupsDirectory + "shared/\(setup.id!)/"
                )
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
                throw WebAssignmentError.internalFailure(
                    reason: "Expression evaluator failed: \(error)")
            }
        }

        // 5. Re-render through `applyPatternFamilies` so generated tests
        // and raw scripts pick up the new literal values.  Expressions
        // flow through unchanged — they don't affect test scripts in
        // this slice, only notebook substitution at first-open.
        _ = try await applyPatternFamilies(
            to: setup,
            nextFamilies: manifest.patternFamilies,
            nextChecks: manifest.notebookChecks,
            authoredItems: nil,
            sections: manifest.sections,
            globalVariables: body.variables,
            globalExpressions: expressions,
            on: req.db
        )

        // 6. Re-load the persisted manifest so the response reflects
        // reconciled state.
        let updatedManifest = try decodeManifest(setup: setup)
        return GlobalVariablesResponse(
            variables: updatedManifest.globalVariables,
            expressions: updatedManifest.globalExpressions,
            warnings: []
        )
    }

    // MARK: - helpers

    private func decodeManifest(setup: APITestSetup) throws -> TestProperties {
        guard let data = setup.manifest.data(using: .utf8),
            let manifest = try? ManifestCodec.decoder.decode(TestProperties.self, from: data)
        else {
            throw WebAssignmentError.internalFailure(reason: "Manifest is not valid JSON.")
        }
        return manifest
    }
}
