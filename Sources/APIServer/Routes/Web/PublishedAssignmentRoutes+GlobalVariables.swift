// APIServer/Routes/Web/PublishedAssignmentRoutes+GlobalVariables.swift
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

extension PublishedAssignmentRoutes {

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
        let (_, setup) = try await loadAssignmentAndSetup(req)
        let result = try GlobalInputsService.current(setup: setup)
        return GlobalVariablesResponse(
            variables: result.variables,
            expressions: result.expressions,
            warnings: result.warnings
        )
    }

    // MARK: - PUT /instructor/:assignmentID/global-variables

    @Sendable
    func putGlobalVariables(req: Request) async throws -> GlobalVariablesResponse {
        let (assignment, setup) = try await loadAssignmentAndSetup(req)
        let body = try req.content.decode(GlobalVariablesBody.self)

        // The save-time expression check evaluates against the acting
        // instructor's own seed; resolve it from the session (absent in
        // pathological unauth states, in which case the eval check is skipped).
        let actingUserID = (try? req.auth.require(APIUser.self))?.id

        let result = try await GlobalInputsService.apply(
            setup: setup,
            assignment: assignment,
            actingUserID: actingUserID,
            inputs: .init(variables: body.variables, expressions: body.expressions ?? []),
            testSetupsDirectory: req.application.testSetupsDirectory,
            on: req.db
        )
        return GlobalVariablesResponse(
            variables: result.variables,
            expressions: result.expressions,
            warnings: result.warnings
        )
    }
}
