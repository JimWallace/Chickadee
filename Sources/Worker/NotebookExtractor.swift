import Core
import Foundation
import RunnerCore

struct NotebookExtraction {
    let source: String
    let introspectableSource: String
    let codeCellCount: Int
}

struct NotebookExtractor {
    func notebookJSONObject(from data: Data, filename: String) throws -> [String: Any] {
        let rawObject: Any
        do {
            rawObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SubmissionNormalizationError.invalidNotebookJSON(filename)
        }
        guard let object = rawObject as? [String: Any] else {
            throw SubmissionNormalizationError.invalidNotebookJSON(filename)
        }
        return object
    }

    func isNotebookJSONObject(_ notebook: [String: Any]) -> Bool {
        guard notebook["metadata"] != nil,
            notebook["nbformat"] != nil,
            notebook["cells"] is [[String: Any]] || notebook["cells"] is [Any]
        else {
            return false
        }
        return true
    }

    func extractPythonSource(from notebook: [String: Any], filename: String) throws -> NotebookExtraction {
        guard let cells = notebook["cells"] as? [[String: Any]] else {
            throw SubmissionNormalizationError.invalidSubmission(filename, .python)
        }

        // Delegate to the shared, dependency-free core so the native worker and
        // the (wasm) browser runner extract notebooks identically.
        let inputCells = cells.map { cell in
            NotebookCell(
                cellType: (cell["cell_type"] as? String) ?? "",
                source: NotebookCellSources.cellSource(cell)
            )
        }
        let extracted = extractPython(cells: inputCells, filename: filename)

        guard extracted.codeCellCount > 0 else {
            throw SubmissionNormalizationError.notebookHasNoCodeCells(filename)
        }

        return NotebookExtraction(
            source: extracted.executableModule,
            introspectableSource: extracted.introspectableSource,
            codeCellCount: extracted.codeCellCount
        )
    }

    // The per-cell transforms now live in RunnerCore (the single, wasm-ready
    // source of truth shared with the browser runner). These thin wrappers are
    // kept so existing call sites and tests stay unchanged — they must qualify
    // the core functions to avoid recursing into themselves.

    func sanitizeCellForModule(_ source: String) -> String {
        RunnerCore.sanitizeCellForModule(source)
    }

    func wrapCellForResilientLoad(_ body: String, label: String) -> String {
        RunnerCore.wrapCellForResilientLoad(body, label: label)
    }

    func pythonStringLiteral(_ s: String) -> String {
        RunnerCore.pythonStringLiteral(s)
    }
}

/// One notebook's language and cells, after the submission policy has had its
/// say. Nil means "skip this file" — only ever returned for a notebook that is
/// not the student's own.
private struct ResolvedNotebook {
    let language: AssignmentLanguage
    let cells: [[String: Any]]
}

/// Read a notebook, decide its language, and apply the submission guarantees.
///
/// Split out of `extractNotebooksToCode` because it is the whole policy step and
/// the loop around it is just file plumbing — and because inlining both pushed
/// that function past the cyclomatic-complexity limit, which was a fair signal
/// rather than a threshold to raise.
private func resolveNotebookForExtraction(
    at item: URL,
    forcedLanguage: AssignmentLanguage?,
    isStudentSubmission: Bool,
    warnings: inout [String]
) throws -> ResolvedNotebook? {
    // The language has to be known before the file can be validated, because
    // the guarantees are declared per language — so the bytes are read
    // leniently first and validated once the language is settled.
    guard let data = try? Data(contentsOf: item) else {
        // Unreadable on disk is an infrastructure fault, not a student one —
        // but for the student's own file it still has to be loud.
        if isStudentSubmission {
            throw SubmissionNormalizationError.invalidNotebookJSON(item.lastPathComponent)
        }
        return nil
    }
    let lenient = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

    // A caller-forced language wins over the notebook's own kernelspec;
    // otherwise sniff it with the shared detector.
    //
    // `fromNotebookMetadata`, not the older boolean `isRNotebook`. The boolean
    // form answers "R or not", so a Lua notebook took the `else` branch and was
    // extracted as PYTHON — a silent wrong answer the compiler could not flag,
    // because `?:` on two cases type-checks perfectly well however many cases
    // exist. The general form returns the language it recognised, or nil to
    // mean "nothing recognisable".
    //
    // Python is named explicitly as the extraction fallback rather than
    // inherited from a resolution default. Unlike resolution, extraction cannot
    // answer "no language" — it has to write a file in some syntax — so an
    // unrecognised kernel is extracted as Python, which is what this has always
    // done. Stating it here keeps that a local, visible choice.
    let language =
        forcedLanguage
        ?? (lenient?["metadata"] as? [String: Any]).flatMap(AssignmentLanguage.fromNotebookMetadata)
        ?? .python

    // For the student's own notebook the policy THROWS a message they can act
    // on; for anything else it stays lenient and merely warns, because failing
    // a job over an instructor's markdown-only helper would be a regression
    // dressed as a fix.
    guard isStudentSubmission else {
        guard let cells = lenient?["cells"] as? [[String: Any]] else {
            if submissionGuaranteeApplies(.unsupportedFilesWarn, to: language) {
                warnings.append(
                    "\(item.lastPathComponent) could not be read as a notebook and was skipped.")
            }
            return nil
        }
        return ResolvedNotebook(language: language, cells: cells)
    }

    let validated = try SubmissionValidation.validatedNotebook(
        data: data, filename: item.lastPathComponent, language: language)
    let cells = (validated["cells"] as? [[String: Any]]) ?? []
    let codeCellCount = cells.filter { ($0["cell_type"] as? String) == "code" }.count
    try SubmissionValidation.requireCodeCells(
        codeCellCount, filename: item.lastPathComponent, language: language)
    return ResolvedNotebook(language: language, cells: cells)
}

// MARK: - Notebook-to-code extraction for test setup directories

/// Extract code cells from all .ipynb notebooks in `directory` into .py or .R source files.
///
/// This replaces the former runner-support/Makefile prep step with a pure-Swift
/// implementation. The .ipynb format is plain JSON — no `make`, Python, or external
/// tools are required. Kernel language detection mirrors the logic in
/// TestSetupRoutes.normalizeNotebookForJupyterLite() and browser-runner.js.
///
/// Module-level (not private) so WorkerTests can exercise it directly.
///
/// - Parameter forcedLanguage: when non-nil, every notebook is extracted to
///   that language regardless of its own kernelspec. The worker passes the
///   language `manifestOwningLanguage` identified, so a submission whose
///   kernelspec was rewritten by the in-browser editor still extracts to the
///   source the suite can actually grade. Nil keeps the per-notebook kernelspec
///   detection, which is what an assignment with no owning language wants.
/// - Parameter studentNotebookName: the filename of the STUDENT's own upload,
///   when known. The submission guarantees in `SubmissionPolicy` are enforced
///   for that file and only that file: a corrupt or empty student notebook is
///   an error they can act on, while an instructor's helper notebook in the
///   same workspace may legitimately be markdown-only and must keep the lenient
///   skip. The Python normalizer gets this scoping for free by walking only the
///   submission directory; this walks the merged workspace, so it has to be
///   told.
/// - Returns: warnings about files that could not be graded — the
///   `unsupportedFilesWarn` guarantee, which the generic path previously did
///   not provide at all.
@discardableResult
func extractNotebooksToCode(
    in directory: URL,
    forcedLanguage: AssignmentLanguage? = nil,
    studentNotebookName: String? = nil
) throws -> [String] {
    let items =
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
    var warnings: [String] = []

    for item in items where item.pathExtension.lowercased() == "ipynb" {
        // Every .ipynb in the directory is extracted to .py (or .R).  The
        // starter template notebook is already removed by process() before
        // this function runs (driven by manifest.starterNotebook), so the
        // only notebooks remaining are the student/canonical submission and
        // any instructor-provided helper notebooks that should be converted.
        let resolved = try resolveNotebookForExtraction(
            at: item,
            forcedLanguage: forcedLanguage,
            isStudentSubmission:
                studentNotebookName
                .map { $0 == item.lastPathComponent } ?? false,
            warnings: &warnings)
        guard let resolved else { continue }
        let language = resolved.language
        let cells = resolved.cells

        // Deliberately not `generatedScriptExtension`: that property is scoped to
        // scripts Chickadee *generates* (pattern cases, notebook checks) where the
        // filename feeds `spec_hash`. Extraction output is a different concern and
        // must not be coupled to it.
        // From the descriptor — see `sourceFileExtension`. Was a hand-written
        // switch identical to SubmissionStaging's.
        let ext = language.sourceFileExtension
        let stem = item.deletingPathExtension().lastPathComponent
        let outURL = directory.appendingPathComponent("\(stem).\(ext)")

        let output = assembleExtractedSource(
            language: language, cells: cells, filename: item.lastPathComponent)

        try output.write(to: outURL, atomically: true, encoding: .utf8)
    }
    return warnings
}

/// The per-language assembly of one notebook's cells into a source module.
private func assembleExtractedSource(
    language: AssignmentLanguage, cells: [[String: Any]], filename: String
) -> String {
    switch language {
    case .r, .lua, .octave, .cpp, .racket, .java:
        // Flattening concatenates cells, which loses the boundaries a
        // source-level check (`.cellContains`) needs.  Python keeps them
        // because `wrapCellForResilientLoad` labels each cell; the others get
        // the same information from inert marker comments, which
        // `chickadee_student_cells()` splits on.  The assembly lives in
        // RunnerCore (`extractR` / `extractLua` / `extractOctave`, all over one
        // `extractWithCellMarkers`) — the same implementation the browser
        // runner calls via wasm, so the two extractors cannot drift.
        let inputCells = cells.map { cell in
            NotebookCell(
                cellType: (cell["cell_type"] as? String) ?? "",
                source: NotebookCellSources.cellSource(cell)
            )
        }
        // A switch rather than the `== .lua ? … : …` ternary this used to
        // be: the ternary compiles forever and would have routed Octave to
        // the R extractor (runbook item 5's shape, one size smaller).
        let extracted: ExtractedRNotebook
        switch language {
        case .lua: extracted = extractLua(cells: inputCells, filename: filename)
        case .octave: extracted = extractOctave(cells: inputCells, filename: filename)
        case .cpp: extracted = extractCpp(cells: inputCells, filename: filename)
        case .racket: extracted = extractRacket(cells: inputCells, filename: filename)
        case .java: extracted = extractJava(cells: inputCells, filename: filename)
        case .r, .python: extracted = extractR(cells: inputCells, filename: filename)
        }
        return extracted.source
    case .python:
        var assembled = "# Generated from \(filename)\n\n"
        let extractor = NotebookExtractor()
        for (index, cell) in cells.enumerated() {
            guard cell["cell_type"] as? String == "code" else { continue }
            var src = NotebookCellSources.cellSource(cell)
            while src.last?.isWhitespace == true { src.removeLast() }
            guard !src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let cellSource = extractor.sanitizeCellForModule(src)
            guard !cellSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            assembled +=
                extractor.wrapCellForResilientLoad(cellSource, label: "cell \(index + 1)") + "\n\n"
        }
        return assembled
    }
}
