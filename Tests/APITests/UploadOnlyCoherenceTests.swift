// Tests/APITests/UploadOnlyCoherenceTests.swift
//
// The upload-only coherence rule — "a language with no editor kernel must be in
// uploadOnly submission mode" — asserted over `allCases` rather than for
// whichever language someone remembered.
//
// WHY THIS EXISTS. The rule is enforced at five places. Two of them were
// generalised to `EditorSupport` in #1294; the other three still read
// `== .cpp` when Racket shipped as a second upload-only language, so a Racket
// assignment could be flipped back to notebook mode from the MCP tool, the web
// editor, or a zip-borne manifest. Nothing failed — every existing test named
// C++, and C++ still worked.
//
// Swift cannot make a *missing* validation call a compile error, so this is the
// guard that has to be a test. Two things are asserted, and they are different
// questions:
//
//   1. The predicate and the message generalise. Cheap, and it is what catches
//      a sixth site added later reading `== .cpp` — a language that answers
//      `uploadOnly` must produce a refusal naming ITSELF.
//   2. `effectiveSubmissionMode` makes the incoherent pair harmless wherever it
//      arrives anyway. This is the layer that means a missed refusal is a
//      tidiness bug rather than a broken assignment, and it is the one the
//      grading-mode rule already had and this one did not.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct UploadOnlyCoherenceTests {

    /// Every language answers the predicate, and the two upload-only ones are
    /// the ones with no vendored kernel. Pins the pairing itself: a language
    /// that is `uploadOnly` for the editor but not for submissions (or the
    /// reverse) is incoherent by construction.
    @Test(arguments: AssignmentLanguage.allCases)
    func theSubmissionRuleTracksEditorSupport(_ language: AssignmentLanguage) {
        switch language.editorSupport {
        case .uploadOnly:
            #expect(
                requiresUploadOnlySubmission(language),
                "\(language) has no editor kernel but is not required to be upload-only")
        case .notebookKernel:
            #expect(
                !requiresUploadOnlySubmission(language),
                "\(language) has a vendored kernel but is forced upload-only")
        }
    }

    /// The refusal names the language it refused.
    ///
    /// The message was a hardcoded C++ constant, served verbatim by the two
    /// sites whose predicate had already been generalised — so the one author
    /// the fix was for read prose about a different language. A predicate that
    /// generalises without its wording is a rule that reads as a bug.
    @Test(arguments: AssignmentLanguage.allCases)
    func theRefusalNamesTheLanguageItRefused(_ language: AssignmentLanguage) {
        guard requiresUploadOnlySubmission(language) else { return }
        let message = requiresUploadOnlyMessage(language)
        #expect(
            message.contains(language.displayName),
            "the upload-only refusal for \(language) does not name \(language.displayName)")
        for other in AssignmentLanguage.allCases
        where other != language && requiresUploadOnlySubmission(other) {
            #expect(
                !message.contains(other.displayName),
                """
                the upload-only refusal for \(language) names \(other.displayName) — the message \
                is hardcoded to one language again.
                """)
        }
    }

    /// The incoherent pair is inert, not dangerous.
    ///
    /// This is the layer that does not depend on any authoring surface spelling
    /// the rule correctly: however a `notebook` submission mode came to be
    /// stored against a kernel-less language — a hand-crafted zip, an imported
    /// course bundle, a row written before the language existed — consumption
    /// sites see `uploadOnly`.
    @Test(arguments: AssignmentLanguage.allCases)
    func effectiveSubmissionModePinsAKernellessLanguageToUpload(_ language: AssignmentLanguage) {
        for stored in [SubmissionMode.notebook, .uploadOnly] {
            let manifest = TestProperties(
                submissionMode: stored, testSuites: [], language: language)
            let expected: SubmissionMode =
                requiresUploadOnlySubmission(language) ? .uploadOnly : stored
            #expect(
                manifest.effectiveSubmissionMode == expected,
                """
                \(language) with a stored \(stored.rawValue) submission mode resolves to \
                \(manifest.effectiveSubmissionMode.rawValue), expected \(expected.rawValue).
                """)
        }
    }

    /// An assignment with no language keeps whatever it stored.
    ///
    /// The fail-open that has to stay open: a plain `.sh` suite is the system's
    /// original mode and has no language in the `AssignmentLanguage` sense, so
    /// nothing here applies to it.
    @Test func aLanguagelessAssignmentIsUntouched() {
        for stored in [SubmissionMode.notebook, .uploadOnly] {
            let manifest = TestProperties(
                submissionMode: stored, testSuites: [], language: nil)
            #expect(manifest.effectiveSubmissionMode == stored)
        }
    }

    /// Upload-only implies worker grading, transitively.
    ///
    /// `effectiveGradingMode` reads `effectiveSubmissionMode`, so a kernel-less
    /// language whose manifest says `browser` still grades natively — which is
    /// the only answer that can execute, since browser grading needs a notebook
    /// page and a vendored kernel and this language has neither.
    @Test(arguments: AssignmentLanguage.allCases)
    func aKernellessLanguageAlwaysGradesOnTheWorker(_ language: AssignmentLanguage) {
        guard requiresUploadOnlySubmission(language) else { return }
        let manifest = TestProperties(
            gradingMode: .browser, submissionMode: .notebook, testSuites: [],
            language: language)
        #expect(manifest.effectiveGradingMode == .worker)
    }
}
