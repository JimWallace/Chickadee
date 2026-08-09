// APIServer/Services/SolutionNotebookExtractor.swift
//
// Slice 5 of #461 — walks a solution notebook's code cells and writes
// a flat `solution.py` file that personalization expressions can
// `import`.  Built on the SAME `RunnerCore.extractPython` the native
// worker and the (wasm) browser runner use to load a notebook for
// grading, so the module expressions import and the module the grader
// runs are one implementation and cannot drift.  That shared extractor
// also loads each cell under its own `try/except` and quarantines
// side-effecting statements into `if __name__ == "__main__":`, so a
// broken demo/example cell (a JSON-ism like `null`, a failing
// module-level `assert`) is skipped without taking the instructor's
// helper functions down with it.
//
// Lives parallel to `extractSupportFilesToSharedDirectory` in
// `TestSetupZipHelpers.swift`: called after every test-setup save so
// `shared/{setupID}/solution.py` stays in sync with the canonical
// `solution.ipynb` in the test setup zip.  Skipped when the instructor
// uploaded a `solution.py` of their own — explicit beats derived.

import Core
import Foundation

enum SolutionNotebookExtractor {

    /// Renders the supplied solution notebook's `code` cells into a single,
    /// importable Python module.  Markdown / raw cells are skipped.  Returns nil
    /// when the input isn't a valid notebook or has no code cells.
    ///
    /// Built on the shared `RunnerCore.extractPython` — the SAME extractor the
    /// native worker and the (wasm) browser runner use to load a notebook for
    /// grading.  Two properties matter here:
    ///
    /// 1. **One implementation, no drift.**  The `solution.py` that
    ///    personalization expressions import is produced by the very code path
    ///    that grades the reference solution, so a generated expected value
    ///    (`solution.<fn>(...)`) can't silently diverge from what the grader
    ///    actually runs.
    /// 2. **Resilient per-cell load.**  Each cell loads under its own
    ///    `try/except`, and side-effecting / control-flow statements are
    ///    quarantined into `if __name__ == "__main__":`.  A broken demo or
    ///    example cell — a JSON-ism like a bare `null`, a failing module-level
    ///    `assert`, a `Patient(...)` call referencing data that isn't there —
    ///    is skipped WITHOUT taking the instructor's helper functions down with
    ///    it.  The previous naive concat let any such cell abort `import
    ///    solution` entirely; the evaluator's import guard then swallowed the
    ///    error, surfacing as a baffling `name 'solution' is not defined` at the
    ///    first `solution.<fn>` reference instead of a localized failure.
    static func extractCodeToPython(notebookData: Data) -> String? {
        guard let cells = NotebookCellSources.cells(from: notebookData) else { return nil }

        let inputCells = cells.map { cell in
            NotebookCell(
                cellType: (cell["cell_type"] as? String) ?? "",
                source: NotebookCellSources.cellSource(cell))
        }
        let extracted = extractPython(cells: inputCells, filename: "solution.ipynb")
        guard extracted.codeCellCount > 0 else { return nil }

        let header = """
            # Auto-generated from solution.ipynb by Chickadee.
            # Imported by personalization expressions to call the instructor's
            # canonical helpers (e.g. `solution.classify_bmi(...)`) — one source
            # of truth, so a generated expected value can't drift from the
            # reference solution.  Regenerated on every solution save; do not
            # edit by hand.  Each cell loads resiliently, so one broken demo or
            # example cell can't stop the helper functions from importing.

            """
        return header + extracted.executableModule
    }

    /// Writes `solution.py` into `sharedDirectory` from
    /// `solutionNotebookData` if and only if:
    /// - the notebook contains at least one non-empty code cell, AND
    /// - `sharedDirectory` doesn't already contain a `solution.py`
    ///   (instructor-uploaded support files take precedence).
    ///
    /// Returns true if a file was written.  Errors are swallowed
    /// (logged in production by the caller); the personalization
    /// evaluator works without solution.py present.
    @discardableResult
    static func writeSolutionPyIfNeeded(
        notebookData: Data,
        sharedDirectory: String
    ) -> Bool {
        writeSolutionPy(notebookData: notebookData, sharedDirectory: sharedDirectory, overwrite: false)
    }

    /// Like `writeSolutionPyIfNeeded`, but `overwrite: true` refreshes an
    /// existing `solution.py`.  Used by the solution-save path so the
    /// server-side `shared/{setupID}/solution.py` the personalization
    /// evaluator imports stays in lockstep with the instructor's reference
    /// solution — the keystone that lets a Global Input expression compute an
    /// expected value as `solution.<fn>(...)` instead of a parallel answer key
    /// that can drift.  `solution.py` lives ONLY in the shared directory; it is
    /// never written into the test-setup zip, so it never reaches the worker,
    /// the browser, or a student support-file download (mirroring the reserved
    /// treatment of `solution.ipynb`).
    ///
    /// With `overwrite: false` an existing `solution.py` is left alone so an
    /// instructor-uploaded support file still wins.
    @discardableResult
    static func writeSolutionPy(
        notebookData: Data,
        sharedDirectory: String,
        overwrite: Bool
    ) -> Bool {
        let fm = FileManager.default
        let target = (sharedDirectory as NSString).appendingPathComponent("solution.py")

        // Don't clobber an instructor-uploaded solution.py unless asked to.
        if fm.fileExists(atPath: target) && !overwrite { return false }

        guard let py = extractCodeToPython(notebookData: notebookData) else { return false }
        // Skip when the notebook had no executable cells — writing an
        // empty `solution.py` would shadow nothing useful.
        let effectiveLines =
            py
            .split(separator: "\n", omittingEmptySubsequences: false)
            .drop(while: { $0.hasPrefix("#") || $0.trimmingCharacters(in: .whitespaces).isEmpty })
        guard !effectiveLines.isEmpty else { return false }

        do {
            // Make sure the directory exists; the caller usually creates
            // it via extractSupportFilesToSharedDirectory but defend
            // against an out-of-order call.
            try fm.createDirectory(
                atPath: sharedDirectory,
                withIntermediateDirectories: true)
            try py.write(toFile: target, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Every other language

    /// Extracts a solution notebook to source in `language`, or nil when the
    /// notebook holds no executable cells.
    ///
    /// WHY THIS EXISTS. `extractCodeToPython` above is Python-only, and it was
    /// the ONLY solution extraction the server did — so `shared/<setup>/` held a
    /// `solution.py` and nothing else. An R, Lua, Octave or Racket
    /// personalization expression therefore could not call the reference
    /// solution at all: `supportFileEntries` looked for `.R` / `.lua` / `.m` /
    /// `.rkt` helpers in that directory and the solution was never among them.
    /// The expression failed, or worse, quietly resolved a name to nothing.
    ///
    /// The extractors themselves already existed in RunnerCore for the worker's
    /// submission path (`extractR` / `extractLua` / `extractOctave` /
    /// `extractCpp` / `extractRacket`); only the server half was missing. This
    /// reuses them, so the reference solution the evaluator loads is assembled
    /// by the same code that assembles a student's submission.
    static func extractCode(
        notebookData: Data, language: AssignmentLanguage
    ) -> (source: String, filename: String)? {
        let filename = "solution.\(language.sourceFileExtension)"
        if language == .python {
            guard let py = extractCodeToPython(notebookData: notebookData) else { return nil }
            return (py, filename)
        }
        guard let cells = NotebookCellSources.cells(from: notebookData) else { return nil }
        let inputCells = cells.map { cell in
            NotebookCell(
                cellType: (cell["cell_type"] as? String) ?? "",
                source: NotebookCellSources.cellSource(cell))
        }
        // Exhaustive so a seventh language cannot inherit another's extractor —
        // the `isRNotebook(nb) ? .r : .python` shape one size smaller.
        let extracted: ExtractedRNotebook
        switch language {
        case .r: extracted = extractR(cells: inputCells, filename: "solution.ipynb")
        case .lua: extracted = extractLua(cells: inputCells, filename: "solution.ipynb")
        case .octave: extracted = extractOctave(cells: inputCells, filename: "solution.ipynb")
        case .cpp: extracted = extractCpp(cells: inputCells, filename: "solution.ipynb")
        case .racket: extracted = extractRacket(cells: inputCells, filename: "solution.ipynb")
        case .python: return nil  // handled above
        }
        guard extracted.codeCellCount > 0 else { return nil }
        return (extracted.source, filename)
    }

    /// Writes `solution.<ext>` for `language` into `sharedDirectory`.
    ///
    /// The language-aware sibling of `writeSolutionPy`, with the same
    /// precedence rule: an instructor-uploaded file of that name wins unless
    /// `overwrite` is set.
    @discardableResult
    static func writeSolutionSource(
        notebookData: Data,
        sharedDirectory: String,
        language: AssignmentLanguage,
        overwrite: Bool
    ) -> Bool {
        // Python keeps its own path byte-for-byte: it has resilient per-cell
        // loading and an emptiness rule the generic extractors do not share,
        // and every existing assignment depends on those bytes.
        if language == .python {
            return writeSolutionPy(
                notebookData: notebookData, sharedDirectory: sharedDirectory, overwrite: overwrite)
        }
        guard let extracted = extractCode(notebookData: notebookData, language: language) else {
            return false
        }
        let fm = FileManager.default
        let target = (sharedDirectory as NSString).appendingPathComponent(extracted.filename)
        if fm.fileExists(atPath: target) && !overwrite { return false }
        do {
            try fm.createDirectory(atPath: sharedDirectory, withIntermediateDirectories: true)
            try extracted.source.write(toFile: target, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    // Cell-source reading (`readCellSource`) moved to
    // `Core/NotebookCellSources.swift` (`cellSource(_:)`) in v0.4.181.
}
