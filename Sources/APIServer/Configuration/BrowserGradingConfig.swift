// APIServer/Configuration/BrowserGradingConfig.swift
//
// Which substrate the browser grader runs Python on (#1271).
//
// R has only one answer — the vendored xeus-r kernel is the only way to grade R
// in a browser at all — so this knob is Python-only. Python has two working
// substrates and the choice between them is a rollout decision, not a code one:
//
//   .pyodide  the historical substrate, and the DEFAULT. Resolves imports at
//             run time from the vendored 363-package index.
//   .xeus     the `chickadee-python` kernel the notebook editor already runs,
//             so authoring and grading become one environment. Its package set
//             is fixed at build time by Tools/jupyterlite/environment-python.yml
//             and there is no runtime install escape hatch under
//             `connect-src 'self'`.
//
// That last sentence is why this is a flag and not a switch. Moving a
// deployment to `.xeus` narrows what a test script or submission may import,
// from "resolved on demand" to "whatever is baked in". Chickadee's generated
// tests import nothing outside the env, and students are already held to it by
// the editor — but hand-authored scripts are not, and an unsatisfiable import is
// an unrecoverable ImportError at grade time. Scan the deployment's test setups
// before flipping; see docs/xeus-python-grading-migration-plan.md §0.
//
// A bad flip is recoverable: a substrate that cannot initialise aborts the grade
// and the submission fails over to the native worker (slow, not wrong). A
// missing *package* is not caught by that path — it grades as a per-test error —
// which is the whole reason the default stays `.pyodide` until someone decides
// otherwise for their own content.

import Foundation
import Vapor

/// The runtime that executes Python test scripts in the student's browser.
enum BrowserPythonSubstrate: String, Sendable, CaseIterable {
    case pyodide
    case xeus
}

struct BrowserGradingConfig: Sendable {
    let pythonSubstrate: BrowserPythonSubstrate

    static let `default` = BrowserGradingConfig(pythonSubstrate: .pyodide)

    /// `BROWSER_PYTHON_SUBSTRATE=pyodide|xeus`. Anything unrecognised (or unset)
    /// keeps the default rather than failing startup: this is a rollout knob, and
    /// a typo in it must not take a deployment down.
    static func fromEnvironment() -> BrowserGradingConfig {
        guard
            let raw = Environment.get("BROWSER_PYTHON_SUBSTRATE")?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !raw.isEmpty,
            let substrate = BrowserPythonSubstrate(rawValue: raw)
        else {
            return .default
        }
        return BrowserGradingConfig(pythonSubstrate: substrate)
    }
}
