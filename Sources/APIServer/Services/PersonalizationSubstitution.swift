// APIServer/Services/PersonalizationSubstitution.swift
//
// HTTP-free core that builds the `{{name}}` substitution map a student with a
// given seed would see at notebook first-open: every global + section literal
// value, then every global + section expression evaluated against the seed
// (expressions override same-named literals, matching the editor's precedence).
//
// Extracted from `WebRoutes+Notebook.applyNotebookSubstitutionsIfNeeded` so the
// student first-open path and the MCP `preview_personalization` tool resolve
// personalization identically. Expression eval failures are returned (not
// logged) so each caller decides whether to log or surface them.

import Core
import Foundation

enum PersonalizationSubstitution {

    struct Resolution: Sendable {
        /// Resolved `name → Python-literal` map (literals + evaluated expressions).
        let substitutions: [String: String]
        /// Literal (static) input names in scope, global-then-section order.
        let staticNames: [String]
        /// Expression names that successfully evaluated for this seed.
        let evaluatedExpressionNames: [String]
        /// Non-nil when expressions were declared + a seed was supplied but the
        /// per-seed eval failed; the map then carries literals only.
        let evaluationError: String?
    }

    /// Builds the substitution map for `seedHex`.  When `seedHex` is nil, or no
    /// expressions are declared, only literal values are returned (no eval is
    /// attempted).
    static func resolve(
        manifest: TestProperties,
        seedHex: String?,
        supportFilesDirectory: String?
    ) async -> Resolution {
        // Combined static name pool — global first, then sections, so a
        // same-named section variable shadows a global (matches the runner).
        var staticVars: [FamilyVariable] = manifest.globalVariables
        for section in manifest.sections {
            staticVars.append(contentsOf: section.variables)
        }
        var substitutions: [String: String] = [:]
        for v in staticVars {
            substitutions[v.name] = v.value.pythonLiteral
        }

        var allExpressions: [PersonalizationExpression] = manifest.globalExpressions
        for section in manifest.sections {
            allExpressions.append(contentsOf: section.expressions)
        }

        guard !allExpressions.isEmpty, let seedHex else {
            return Resolution(
                substitutions: substitutions,
                staticNames: staticVars.map(\.name),
                evaluatedExpressionNames: [],
                evaluationError: nil)
        }

        do {
            let evaluated = try await PersonalizationEvaluator.evaluate(
                seedHex: seedHex,
                staticVariables: staticVars,
                expressions: allExpressions,
                supportFilesDirectory: supportFilesDirectory)
            // Per-student values override literals on name collision (the
            // validator forbids cross-kind clashes at save time anyway).
            for (name, literal) in evaluated {
                substitutions[name] = literal
            }
            return Resolution(
                substitutions: substitutions,
                staticNames: staticVars.map(\.name),
                evaluatedExpressionNames: allExpressions.map(\.name),
                evaluationError: nil)
        } catch {
            return Resolution(
                substitutions: substitutions,
                staticNames: staticVars.map(\.name),
                evaluatedExpressionNames: [],
                evaluationError: "\(error)")
        }
    }
}
