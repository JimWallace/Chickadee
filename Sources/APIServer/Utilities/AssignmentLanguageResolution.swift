// APIServer/Utilities/AssignmentLanguageResolution.swift
//
// One server-side entry point for "what language is this assignment?", so no
// route, service or MCP tool has to remember which signals exist or in which
// order they win.

import Core
import Foundation

extension AssignmentLanguage {

    /// The assignment's language, including its starter notebook.
    ///
    /// Prefer this over `resolve(manifest:)` anywhere an `APITestSetup` is in
    /// scope. A brand-new notebook assignment has an empty suite and no
    /// recorded language, so the manifest alone answers `.python` — which sent
    /// an instructor's first R `=` expression to `python3` and rejected it with
    /// a Python `SyntaxError` before any `.R` script existed to give the game
    /// away. On that first save the kernelspec is the only signal there is, and
    /// getting it wrong is sticky: the save records the resolved language into
    /// the manifest.
    ///
    /// The notebook is only read when the manifest can't answer on its own
    /// (see the `@autoclosure` on the Core overload), so this stays cheap on
    /// the worker-job and suite-save paths.
    static func resolve(for setup: APITestSetup, manifest: TestProperties) -> AssignmentLanguage {
        resolve(
            manifest: manifest,
            notebookData: setup.notebookPath.flatMap { FileManager.default.contents(atPath: $0) })
    }
}
