// Worker/SubmissionPolicy.swift
//
// What Chickadee promises a student about their upload, stated once, in one
// place, for every language.
//
// WHY THIS IS A POLICY VALUE AND NOT A PROTOCOL. The obvious shape here is a
// `SubmissionNormalizer` protocol with a conformance per language. It is the
// wrong one, for two reasons:
//
//   1. A protocol scatters the policy across N conformances, where it cannot be
//      read as policy. The whole point is that an instructor or a maintainer can
//      look at ONE list and know what a student is guaranteed.
//   2. A protocol makes opting out INVISIBLE. An empty method body, or an
//      inherited default, is indistinguishable from a decision nobody made —
//      which is exactly how R and Lua ended up with no validation at all. Here
//      an exemption is a value with a reason attached, and the reason is
//      greppable.
//
// It is also not where the variation is. Walking the upload, MIME-classifying
// it, checking that a notebook is valid JSON and has code cells, warning on
// files we cannot grade — none of those are language questions. The genuinely
// per-language part is which extractor runs and what the output is called, and
// that already lives in RunnerCore (`extractPython` / `extractR` / `extractLua`).
// A protocol would have pushed the shared 90% into a default implementation,
// which is where the policy is hiding today.
//
// THE STANDARD THIS SETS. Most guarantees have NO exemption, deliberately.
// There is no honest reason for an R student to get silence where a Python
// student gets a message — that difference was never decided, it is just
// unbuilt. The release valve exists for things that are genuinely shaped by the
// language, and keeping that list short is what makes this a platform policy
// rather than a per-language grab-bag.

import Core
import Foundation

/// One promise Chickadee makes about a student's submission.
///
/// `CaseIterable` because the conformance test walks
/// `SubmissionGuarantee.allCases × AssignmentLanguage.allCases`: a new guarantee
/// and a new language both have to be answered rather than defaulted.
enum SubmissionGuarantee: String, CaseIterable, Sendable {
    /// A file that claims to be a notebook parses as JSON and is shaped like a
    /// notebook. Otherwise the student is told so by name.
    case validNotebookJSON

    /// A submitted notebook contains at least one code cell. Otherwise the
    /// student is told, instead of the suite later reporting that no submission
    /// was found — which reads as their fault and is not.
    case notebookHasCodeCells

    /// A file that cannot be graded produces a WARNING and does not fail the
    /// submission. Students routinely include READMEs, data and images.
    case unsupportedFilesWarn

    /// A submission that yielded no gradeable source at all is an error naming
    /// the language, not an empty pass.
    case producedSourceOrErrored

    /// An un-wrapped copy of the source is written beside the executable one so
    /// structural checks can read real definitions out of it.
    case introspectableSidecar
}

/// Why `language` does not provide `guarantee`, or nil when it does.
///
/// EXHAUSTIVE ON BOTH AXES on purpose. A new language cannot compile without
/// answering every guarantee, and a new guarantee cannot compile without being
/// answered for every language — the two ways this could silently regress.
///
/// A non-nil reason is a release valve, and it is a real one: it appears in the
/// conformance test's output and in the runner's structured log when a
/// guarantee is skipped, so an exemption is a thing someone chose and can be
/// argued with, not an absence.
func submissionGuaranteeExemption(
    _ guarantee: SubmissionGuarantee, for language: AssignmentLanguage
) -> String? {
    switch guarantee {
    case .validNotebookJSON, .notebookHasCodeCells, .unsupportedFilesWarn,
        .producedSourceOrErrored:
        // Universal. These are properties of the UPLOAD, not of the language:
        // a corrupt notebook is corrupt whatever kernel wrote it, and a student
        // who gets silence cannot act on it in any language.
        switch language {
        case .python, .r, .lua, .octave, .cpp: return nil
        }

    case .introspectableSidecar:
        switch language {
        case .python:
            return nil
        case .r, .lua, .octave, .cpp:
            // A genuine language-shaped exemption rather than unbuilt work. The
            // sidecar exists so `astStructure` notebook checks can introspect
            // real module-level definitions, and `astStructure` is Python-only
            // by design — it inspects a Python AST, which has no meaning
            // elsewhere. Nothing would ever read the file.
            return "astStructure checks are Python-only, so nothing would read the sidecar"
        }
    }
}

/// Whether `language` provides `guarantee`.
func submissionGuaranteeApplies(
    _ guarantee: SubmissionGuarantee, to language: AssignmentLanguage
) -> Bool {
    submissionGuaranteeExemption(guarantee, for: language) == nil
}

// MARK: - The checks themselves

/// The shared implementation of the notebook guarantees, so both the Python
/// normalizer and the generic extractor enforce one standard rather than two.
///
/// Before this existed, the generic path read `guard let … else { continue }`:
/// a corrupt or empty notebook was silently skipped, no file was produced, and
/// the student's suite then reported "No R submission file was found to grade"
/// — blaming them for a platform failure.
enum SubmissionValidation {

    /// Parse and validate a file that is supposed to be a notebook.
    static func validatedNotebook(
        data: Data,
        filename: String,
        language: AssignmentLanguage
    ) throws -> [String: Any] {
        guard submissionGuaranteeApplies(.validNotebookJSON, to: language) else {
            // Exempt: parse leniently and let the caller skip on failure.
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SubmissionNormalizationError.invalidNotebookJSON(filename)
        }
        guard object["metadata"] != nil, object["nbformat"] != nil,
            object["cells"] is [[String: Any]] || object["cells"] is [Any]
        else {
            throw SubmissionNormalizationError.invalidSubmission(filename, language)
        }
        return object
    }

    /// Enforce the code-cell guarantee for the STUDENT's notebook.
    ///
    /// Scoped to the student's own file on purpose. An instructor's helper
    /// notebook in the workspace may legitimately be markdown-only, and failing
    /// a job over one would be a regression, not a fix. The Python path already
    /// had this scoping implicitly — it only ever walks the submission
    /// directory — and the generic path walks the merged workspace, so it has
    /// to be explicit.
    static func requireCodeCells(
        _ count: Int,
        filename: String,
        language: AssignmentLanguage
    ) throws {
        guard submissionGuaranteeApplies(.notebookHasCodeCells, to: language) else { return }
        guard count > 0 else {
            throw SubmissionNormalizationError.notebookHasNoCodeCells(filename)
        }
    }
}
