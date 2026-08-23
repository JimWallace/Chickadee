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
    ///
    /// `language` selects how literals are rendered (`pythonLiteral` vs
    /// `rLiteral`) and which interpreter evaluates the `=` expressions, so an R
    /// notebook's `{{name}}` placeholders receive R literals and a Python one
    /// stays byte-for-byte identical.
    ///
    /// A nil `language` renders as Python. Rendering is not the same question as
    /// resolution: "what language is this assignment?" can honestly answer
    /// nothing, but "what syntax do I write this literal in?" cannot — there is
    /// no literal without a syntax. So the fallback lives HERE, one visible line
    /// at the site that needs it, instead of inside resolution where every
    /// caller inherited it and none could see it.
    ///
    /// It fires only for an assignment that names no language at all. A real R,
    /// Lua, Octave or C++ assignment resolves positively and never reaches it —
    /// which is the property the Optional buys.
    static func resolve(
        manifest: TestProperties,
        seedHex: String?,
        supportFilesDirectory: String?,
        language: AssignmentLanguage?
    ) async -> Resolution {
        let language = language ?? .python
        // Combined static name pool — global first, then sections, so a
        // same-named section variable shadows a global (matches the runner).
        var staticVars: [FamilyVariable] = manifest.globalVariables
        for section in manifest.sections {
            staticVars.append(contentsOf: section.variables)
        }
        var substitutions: [String: String] = [:]
        for v in staticVars {
            substitutions[v.name] = language.literal(v.value)
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

        // The student's dataset slices, so an expression reading a per-student
        // dataset sees what that student holds.  Resolved from the same source
        // directory and seed the delivered file comes from, so the expression
        // and the student's copy are the same bytes by construction rather than
        // by two call sites agreeing.  Nil for every assignment declaring no
        // datasets, which leaves the evaluation exactly as it was.
        let datasetFiles =
            supportFilesDirectory.flatMap {
                DatasetResolver.resolve(
                    manifest: manifest, seedHex: seedHex, sourceDirectory: $0)
            } ?? [:]

        do {
            let evaluated = try await PersonalizationEvaluator.evaluate(
                seedHex: seedHex,
                staticVariables: staticVars,
                expressions: allExpressions,
                supportFilesDirectory: supportFilesDirectory,
                datasetFiles: datasetFiles,
                language: language)
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

    /// Per-student grading inputs for a submission: each `=` expression's
    /// evaluated value (a Python literal), keyed by name, for `seedHex`.
    /// Literal variables are excluded — those are inlined into scripts at save
    /// time; only expression values need to travel to grading time. Returns nil
    /// when there's no seed, the manifest declares no expressions, or nothing
    /// evaluated (e.g. an expression raised) — callers then ship no
    /// `_ck_inputs.py` and generated scripts that need a value fail closed.
    ///
    /// Shared by the worker job payload (`WorkerJobRoutes`) and the browser
    /// seed endpoint (`BrowserRunnerRoutes`) so both grade identically.
    static func gradingInputs(
        manifest: TestProperties,
        seedHex: String?,
        supportFilesDirectory: String?,
        language: AssignmentLanguage?
    ) async -> [String: String]? {
        guard let seedHex, !seedHex.isEmpty else { return nil }
        guard manifest.hasExpressions else { return nil }
        let resolution = await resolve(
            manifest: manifest, seedHex: seedHex, supportFilesDirectory: supportFilesDirectory,
            language: language)
        let exprNames = Set(resolution.evaluatedExpressionNames)
        let values = resolution.substitutions.filter { exprNames.contains($0.key) }
        return values.isEmpty ? nil : values
    }
}
