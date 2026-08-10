// Tests/APITests/AuthoringLanguageFactsTests.swift
//
// The authoring UI's per-language facts, asserted over `allCases`.
//
// The editor these feed (`Public/pattern-family-editor.js`) contained the string
// "language" zero times: it validated Python identifiers, accepted `True` /
// `False` / `None`, echoed Python reprs, and offered "— Python default —" on
// every assignment, while the server rendered the same family correctly as R,
// Lua, Octave, C++ or Racket. The generated test was right and every hint given
// while authoring it was wrong.
//
// The point of these assertions is that the facts are DERIVED from
// `JSONValue.literal(_:)` — the same call that renders the real generated test —
// so a rendering change cannot leave the editor showing an older spelling. A
// hand-written table in JS could; that is why there isn't one.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct AuthoringLanguageFactsTests {

    /// The scalar spellings are exactly what the renderer emits.
    ///
    /// Pinned as an identity rather than a literal table on purpose: a table
    /// would be the second source of truth this design exists to avoid.
    @Test(arguments: AssignmentLanguage.allCases)
    func scalarSpellingsComeFromTheRenderer(_ language: AssignmentLanguage) {
        let facts = AuthoringLanguageFacts(language)
        #expect(facts.trueLiteral == language.literal(.bool(true)))
        #expect(facts.falseLiteral == language.literal(.bool(false)))
        #expect(facts.name == language.rawValue)
        #expect(facts.displayName == language.displayName)
    }

    /// A language that cannot render null offers no null token.
    ///
    /// C++'s `literal(.null)` is the poison identifier its renderer emits so a
    /// leak becomes a compile error. Handing that to an instructor as something
    /// to type would be worse than offering nothing.
    @Test(arguments: AssignmentLanguage.allCases)
    func onlyLanguagesWithANullValueOfferANullToken(_ language: AssignmentLanguage) {
        let facts = AuthoringLanguageFacts(language)
        if JSONValue.null.cppRenderabilityIssue != nil, language == .cpp {
            #expect(facts.nullLiteral == nil, "C++ must not offer a null token")
        } else {
            #expect(facts.nullLiteral == language.literal(.null))
        }
        // Whatever a language does offer must be something a human could type:
        // never the renderer's internal refusal sentinel.
        if let nullLiteral = facts.nullLiteral {
            #expect(
                !nullLiteral.contains("UNRENDERABLE"),
                "\(language) offers \(nullLiteral) as a null token — that is a poison value")
        }
    }

    /// The three scalar tokens are distinct within a language.
    ///
    /// Two that collide would make the editor's entry parser answer one of them
    /// for both — silently, and in a value that decides marks.
    @Test(arguments: AssignmentLanguage.allCases)
    func scalarTokensAreDistinct(_ language: AssignmentLanguage) {
        let facts = AuthoringLanguageFacts(language)
        let tokens = [facts.trueLiteral, facts.falseLiteral, facts.nullLiteral].compactMap { $0 }
        #expect(Set(tokens).count == tokens.count, "\(language) spells two scalars the same way")
    }

    /// Python's facts reproduce the editor's previous hardcoded constants
    /// exactly, so nothing changes for a Python assignment.
    @Test func pythonIsByteIdenticalToTheOldHardcodedBehaviour() {
        let facts = AuthoringLanguageFacts(.python)
        #expect(facts.trueLiteral == "True")
        #expect(facts.falseLiteral == "False")
        #expect(facts.nullLiteral == "None")
        #expect(facts.functionScanning)
        #expect(facts.expressionEvaluation)
        // The bools the editor previously hardcoded, reproduced exactly.
    }

    /// An assignment with no language gets the language-less answer, and the
    /// editor falls back to today's behaviour.
    @Test func aLanguagelessAssignmentHasNoFacts() {
        let facts = AuthoringLanguageFacts(nil)
        #expect(facts.name == nil)
        #expect(facts.displayName == nil)
        #expect(facts.trueLiteral == nil)
        // No language means no notebook to scan and no driver to evaluate with.
        #expect(!facts.functionScanning)
        #expect(!facts.expressionEvaluation)
    }

    /// Both capability flags are DERIVED from the subsystems that own them,
    /// not restated here.
    ///
    /// This is the assertion that keeps a second copy from growing back. The
    /// flags began as hand-written bools in `AuthoringLanguageFacts` — honest
    /// at the time, and the same duplication bug one level up as soon as the
    /// real answers existed. Scanning belongs to
    /// `notebookFunctionScanSupport`, whose exhaustive switch is the one a
    /// seventh language must satisfy; evaluation belongs to
    /// `PersonalizationEvaluator`, which already spawns a driver per language.
    @Test(arguments: AssignmentLanguage.allCases)
    func capabilityFlagsAreDerivedFromTheirOwners(_ language: AssignmentLanguage) {
        let facts = AuthoringLanguageFacts(language)
        #expect(facts.functionScanning == notebookFunctionScanSupport(for: language).isSupported)
        #expect(facts.expressionEvaluation == PersonalizationEvaluator.supportsEvaluation(language))
    }

    /// Solutions can be scanned in every language that HAS a solution.
    ///
    /// This asserted Python-only, which was true while the scanner read `def `
    /// and nothing else. R, Lua and Octave now have their own definition
    /// parsers; C++ and Racket remain unsupported for a structural reason —
    /// they are upload-only, so there is no solution notebook to scan — and
    /// that arm still has to explain itself.
    @Test(arguments: AssignmentLanguage.allCases)
    func everyLanguageWithASolutionNotebookCanBeScanned(_ language: AssignmentLanguage) {
        let hasNotebookWorkflow: Bool
        switch language.editorSupport {
        case .notebookKernel: hasNotebookWorkflow = true
        case .uploadOnly: hasNotebookWorkflow = false
        }
        #expect(AuthoringLanguageFacts(language).functionScanning == hasNotebookWorkflow)

        let support = notebookFunctionScanSupport(for: language)
        if hasNotebookWorkflow {
            #expect(support.unsupportedReason == nil)
        } else {
            // An unsupported answer is only useful if it explains itself, and
            // names the language it is about.
            let reason = support.unsupportedReason ?? ""
            #expect(!reason.isEmpty, "\(language) is unsupported with no reason given")
            #expect(
                reason.contains(language.displayName),
                "the reason for \(language) does not name \(language.displayName)")
        }
    }

    /// The extension a new hand-written test gets is the language's own, and
    /// is derived rather than tabulated.
    ///
    /// `generatedScriptExtension` is the right owner, and C++ is why: its test
    /// cases are shell wrappers, so the answer there is `sh` and not `cpp`, and
    /// a hand-written C++ test faces exactly the same runner dispatch. Reading
    /// any other source — `scriptExtensions.first`, a table here — would offer
    /// an extension the runner does not execute.
    @Test(arguments: AssignmentLanguage.allCases)
    func theNewScriptExtensionIsTheGeneratedOne(_ language: AssignmentLanguage) {
        #expect(AuthoringLanguageFacts(language).scriptExtension == language.generatedScriptExtension)
    }

    /// A language-less assignment gets no extension to offer. The editor falls
    /// back to `py`, which is what a plain `.sh` suite's authors saw before any
    /// of this and is not worth changing.
    @Test func aLanguagelessAssignmentOffersNoScriptExtension() {
        #expect(AuthoringLanguageFacts(nil).scriptExtension == nil)
    }

    /// Expression evaluation is available in every language, because the
    /// server's evaluator has a driver for every language.
    ///
    /// The editor's own evaluator was a Python kernel, so auto-compute was
    /// Python-only while the server had already solved this six ways.
    @Test(arguments: AssignmentLanguage.allCases)
    func everyLanguageCanEvaluateAnExpression(_ language: AssignmentLanguage) {
        #expect(AuthoringLanguageFacts(language).expressionEvaluation)
    }

    /// An assignment with no language cannot be scanned, and says why.
    @Test func aLanguagelessAssignmentCannotBeScanned() {
        let support = notebookFunctionScanSupport(for: nil)
        #expect(!support.isSupported)
        #expect(support.unsupportedReason?.isEmpty == false)
    }

    /// Unsupported notebook-check kinds are reported, and they agree exactly
    /// with what the save-time validator refuses.
    ///
    /// The "Add Test" menu is a hardcoded catalog in `test-editor-modal.js`. It
    /// offered every kind on every assignment — six a Lua author could not save,
    /// and all ten on C++ or Racket — so the only way to discover a refusal was
    /// to be refused (issue #1290). Deriving the menu's answer from the same
    /// predicate is what keeps the two from disagreeing.
    @Test(arguments: AssignmentLanguage.allCases)
    func unsupportedCheckKindsMatchTheValidator(_ language: AssignmentLanguage) {
        let facts = AuthoringLanguageFacts(language)
        for kind in NotebookCheckKind.allCases {
            let supported = notebookCheckKindIsSupported(kind, language: language)
            let reported = facts.unsupportedCheckKinds[kind.rawValue]
            #expect(
                supported == (reported == nil),
                """
                \(language)/\(kind): the menu says \(reported == nil ? "available" : "unavailable") \
                and the validator says \(supported ? "supported" : "unsupported").
                """)
            if let reported { #expect(!reported.isEmpty, "\(language)/\(kind) has an empty reason") }
        }
    }

    /// Python offers every kind; the two upload-only languages offer none.
    @Test func kindAvailabilityMatchesTheLanguagesShape() {
        #expect(AuthoringLanguageFacts(.python).unsupportedCheckKinds.isEmpty)
        for language in [AssignmentLanguage.cpp, .racket] {
            #expect(
                AuthoringLanguageFacts(language).unsupportedCheckKinds.count
                    == NotebookCheckKind.allCases.count,
                "\(language) is upload-only, so no notebook-check kind applies")
        }
        // R, Lua and Octave are partial — some supported, some not. A language
        // that answered "all" or "none" here would mean the per-kind renderer
        // table had stopped being consulted.
        for language in [AssignmentLanguage.r, .lua, .octave] {
            let unsupported = AuthoringLanguageFacts(language).unsupportedCheckKinds.count
            #expect(unsupported > 0, "\(language) should refuse some kinds")
            #expect(
                unsupported < NotebookCheckKind.allCases.count,
                "\(language) should support some kinds")
        }
    }

    /// The seed is valid JSON with the keys the editor reads.
    @Test func theSeedEncodesTheKeysTheEditorReads() throws {
        let json = authoringLanguageFactsJSON(.r)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["name"] as? String == "r")
        #expect(object["displayName"] as? String == "R")
        #expect(object["trueLiteral"] as? String == "TRUE")
        #expect(object["falseLiteral"] as? String == "FALSE")
        // R's JSON null is NA, not NULL — a NULL vanishes from a list().
        #expect(object["nullLiteral"] as? String == "NA")
        // R gained a definition parser (`f <- function(x)`), so the seed now
        // reports scanning as available. Kept as an explicit assertion rather
        // than deleted: this key is what the create page's scan panel reads.
        #expect(object["functionScanning"] as? Bool == true)
    }
}
