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
    }

    /// An assignment with no language gets the language-less answer, and the
    /// editor falls back to today's behaviour.
    @Test func aLanguagelessAssignmentHasNoFacts() {
        let facts = AuthoringLanguageFacts(nil)
        #expect(facts.name == nil)
        #expect(facts.displayName == nil)
        #expect(facts.trueLiteral == nil)
        #expect(!facts.functionScanning)
        #expect(!facts.expressionEvaluation)
    }

    /// Function scanning and browser evaluation are claimed for Python only.
    ///
    /// Not a design preference — a measurement. `NotebookFunctionScanner`
    /// matches lines beginning `def `, which no R, Lua, Octave or Racket source
    /// produces, and the evaluator is a Python kernel. Claiming either for
    /// another language is how the editor came to report "No functions found."
    /// on a perfectly good R solution.
    @Test(arguments: AssignmentLanguage.allCases)
    func pythonOnlyAidsAreClaimedForPythonOnly(_ language: AssignmentLanguage) {
        let facts = AuthoringLanguageFacts(language)
        #expect(facts.functionScanning == (language == .python))
        #expect(facts.expressionEvaluation == (language == .python))
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
        #expect(object["functionScanning"] as? Bool == false)
    }
}
