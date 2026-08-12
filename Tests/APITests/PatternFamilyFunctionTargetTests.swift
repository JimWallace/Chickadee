// Regression guard for a language-BLIND validation site.
//
// `validatePatternFamilies` checked a family's `functionName` with
// `isValidPythonIdentifier` on EVERY assignment, whatever its language. That
// made two languages unauthorable outright:
//
//   * Java has no free functions, so its target is a qualified `Class.method`
//     — and the dot fails Python's rules. `docs/java-support.md` states the
//     qualified form is required, so the two rules were mutually exclusive and
//     no Java pattern family could be saved at all.
//   * Racket's idiomatic `bmi-category` fails on the hyphen.
//
// Both renderers had already been written believing this check was
// language-aware — `PatternFamilyRendererJava` calls its unqualified branch
// "unreachable through authoring", and the Racket renderer sanitizes an invalid
// name to `ck-invalid-name` — so nothing failed loudly. The family just could
// not be saved, and the refusal named Python on an assignment with no Python in
// it. Found by authoring the first real Java assignment, not by any test.
//
// These assert the OUTCOME an author sees (does the save succeed?), not that a
// particular predicate was called, which is what was true the whole time it was
// broken.

import Core
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct PatternFamilyFunctionTargetTests {

    private func family(function: String) -> PatternFamily {
        PatternFamily(
            id: "bmi",
            name: "BMI category boundaries",
            kind: .boundaryEquality,
            functionName: function,
            paramNames: ["bmi"],
            cases: [
                PatternCase(
                    key: "01", label: "Below the lower boundary",
                    args: [.double(17.2)], expected: .string("underweight"))
            ]
        )
    }

    private func validate(_ function: String, _ language: AssignmentLanguage) throws {
        try validatePatternFamilies([family(function: function)], testSuites: [], language: language)
    }

    // MARK: - The targets each language actually uses

    /// The forms an instructor writes, per language. Every one of these must be
    /// accepted — the two at the end are the ones that were refused.
    @Test(
        arguments: [
            ("bmi_category", AssignmentLanguage.python),
            ("bmi.category", AssignmentLanguage.r),
            ("bmi_category", AssignmentLanguage.lua),
            ("bmi_category", AssignmentLanguage.octave),
            ("bmi_category", AssignmentLanguage.cpp),
            ("bmi-category", AssignmentLanguage.racket),
            ("Solution.bmiCategory", AssignmentLanguage.java),
        ])
    func acceptsTheIdiomaticTarget(function: String, language: AssignmentLanguage) throws {
        try validate(function, language)
    }

    // MARK: - Java requires the qualified form

    /// Java has no free functions, so a bare method name has no class to live
    /// in and the renderer could not emit a call for it.
    @Test func javaRefusesABareName() {
        #expect(throws: (any Error).self) { try validate("bmiCategory", .java) }
    }

    /// More than one dot is not a `Class.method` pair. Guards the split, which
    /// would otherwise silently accept a package-qualified name the renderer
    /// cannot use.
    @Test func javaRefusesADeeperPath() {
        #expect(throws: (any Error).self) { try validate("com.example.Solution.f", .java) }
    }

    /// The refusal has to name the language the author is actually working in,
    /// and say what the accepted form looks like. The old message said
    /// "Python" on a Java assignment, which sends an author looking in exactly
    /// the wrong place.
    @Test func javaRefusalNamesJavaAndTheExpectedForm() throws {
        do {
            try validate("bmiCategory", .java)
            Issue.record("Expected a bare Java method name to be refused")
        } catch let abort as AbortError {
            let reason = "\(abort.reason)"
            #expect(reason.contains("Java"))
            #expect(reason.contains("Class.method"))
            #expect(!reason.contains("Python"))
        }
    }

    // MARK: - The other languages keep their previous behaviour

    /// A dotted name is an R name, not a Python one — so the same string must
    /// be refused on Python and accepted on R. This pins that the fix
    /// discriminates rather than simply relaxing the check for everyone.
    @Test func aDottedNameIsRefusedOnPythonAndAcceptedOnR() throws {
        #expect(throws: (any Error).self) { try validate("bmi.category", .python) }
        try validate("bmi.category", .r)
    }

    /// Likewise a hyphen: legal in Racket, not in the four C-family-ish
    /// languages that share Python's rule.
    @Test func aHyphenatedNameIsRefusedOutsideRacket() throws {
        for language in [AssignmentLanguage.python, .lua, .octave, .cpp] {
            #expect(throws: (any Error).self) { try validate("bmi-category", language) }
        }
        try validate("bmi-category", .racket)
    }

    /// A language's own reserved words must be refused, which is the whole
    /// reason each arm delegates to that language's validator rather than
    /// borrowing Python's. `class` is a perfectly good Python identifier's
    /// shape and a C++ keyword; `switch` likewise for Octave. Rendering either
    /// produces source that cannot compile, so the refusal belongs at save.
    @Test func reservedWordsAreRefusedInTheirOwnLanguage() throws {
        #expect(throws: (any Error).self) { try validate("class", .cpp) }
        #expect(throws: (any Error).self) { try validate("switch", .octave) }
        #expect(throws: (any Error).self) { try validate("Solution.class", .java) }
        // …and are ordinary names elsewhere, so this is discrimination and not
        // a blanket tightening.
        try validate("class_", .cpp)
        try validate("switch_", .octave)
    }

    /// Every language must answer, so a language added later cannot quietly
    /// inherit Python's rule by omission — the failure mode this whole suite
    /// exists to prevent.
    @Test func everyLanguageAcceptsSomeTarget() {
        for language in AssignmentLanguage.allCases {
            let candidates = ["bmi_category", "bmi.category", "bmi-category", "Solution.bmiCategory"]
            #expect(
                candidates.contains { isValidFunctionTarget($0, language: language) },
                "No candidate target is valid for \(language.displayName)")
        }
    }
}
