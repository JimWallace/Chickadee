// Tests/APITests/RunnerLanguageGateTests.swift
//
// Unit tests for the implicit assignment-language gate (RunnerLanguageGate):
// the two fail-open short-circuits (nothing requires an interpreter, no runner
// profile), the closed path when a profile is present without a required
// language, token normalization, the allCases-driven pin that every language is
// gated — including Python, which used to be unrepresentable here because
// resolution could not tell "this is Python" from "we could not tell" — and the
// suite-implied requirements, which the declaration alone cannot see.

import Core
import Testing

@testable import APIServer

@Suite struct RunnerLanguageGateTests {

    /// A manifest that DECLARES `language` and whose suite holds `scripts`.
    /// The two are separate inputs on purpose: the gate has to answer for both.
    private func manifest(
        language: AssignmentLanguage?, scripts: [String] = []
    ) -> TestProperties {
        TestProperties(
            requiredFiles: [],
            testSuites: scripts.map { TestSuiteEntry(tier: .pub, script: $0) },
            timeLimitSeconds: 10,
            language: language,
            languageDeclared: true)
    }

    private func profile(languages: [String]) -> RunnerCapabilityProfile {
        RunnerCapabilityProfile(
            platform: "linux",
            architecture: "x86_64",
            languageVersions: languages.map { LanguageVersion(language: $0, version: "1.0") },
            capabilities: []
        )
    }

    // MARK: - Fail-open short-circuits

    /// A `.sh`-only suite has no interpreter to require. This is the system's
    /// original mode and must stay claimable by any runner.
    @Test func anAssignmentWithNoLanguageIsClaimableByAnyone() {
        let result = RunnerLanguageGate.evaluate(
            runnerProfile: profile(languages: []), manifest: manifest(language: nil))
        #expect(result.isCompatible)
        #expect(result.reasons.isEmpty)
    }

    /// No profile means capability discovery is switched off, which is an
    /// operator's explicit choice. Treating it as incompatible would stop such a
    /// runner claiming anything at all.
    @Test func aRunnerWithNoProfileIsNotBlocked() {
        for language in AssignmentLanguage.allCases {
            #expect(
                RunnerLanguageGate.evaluate(
                    runnerProfile: nil, manifest: manifest(language: language)
                ).isCompatible,
                "a profile-less runner must not be blocked from \(language) work")
        }
    }

    // MARK: - The closed path

    @Test func aProfileWithoutTheLanguageIsRefused() {
        let result = RunnerLanguageGate.evaluate(
            runnerProfile: profile(languages: ["python"]), manifest: manifest(language: .octave))
        #expect(!result.isCompatible)
        #expect(result.reasons.count == 1)
        #expect(result.reasons.first?.contains("octave") == true)
    }

    @Test func aProfileWithTheLanguageIsAdmitted() {
        #expect(
            RunnerLanguageGate.evaluate(
                runnerProfile: profile(languages: ["python", "octave"]),
                manifest: manifest(language: .octave)
            ).isCompatible)
    }

    /// The scenario the gate exists for: a runner whose BUILD predates the
    /// language advertises a profile that simply lacks it, so it leaves the job
    /// for a runner that can grade it instead of failing it with exit 127.
    @Test func anOlderRunnerLeavesANewLanguagesJobAlone() {
        let old = profile(languages: ["python", "r"])
        let current = profile(languages: ["python", "r", "lua", "octave", "cpp"])
        #expect(
            !RunnerLanguageGate.evaluate(
                runnerProfile: old, manifest: manifest(language: .octave)
            ).isCompatible)
        #expect(
            RunnerLanguageGate.evaluate(
                runnerProfile: current, manifest: manifest(language: .octave)
            ).isCompatible)
    }

    /// The case a `minimumRunnerVersion` gate cannot catch: the runner is new
    /// enough, but its HOST has no interpreter, so it never advertises one.
    @Test func aCurrentRunnerMissingTheInterpreterIsAlsoRefused() {
        #expect(
            !RunnerLanguageGate.evaluate(
                runnerProfile: profile(languages: ["python", "r", "lua"]),
                manifest: manifest(language: .octave)
            ).isCompatible)
    }

    // MARK: - What the suite needs, which the declaration cannot see

    /// THE HOLE THIS CLOSES. A suite may legitimately mix languages — the runner
    /// classifies each script independently and stages every language's
    /// `test_runtime.*` — so a hand-written `.R` helper inside a Python
    /// assignment runs under `Rscript`. The gate used to ask only the
    /// declaration, so an R-less runner claimed the job and the `.R` test died
    /// at `exit 127 / Rscript: not found` in front of a student: this gate's own
    /// failure mode, in a shape it could not see.
    @Test func aHandWrittenOffLanguageScriptIsRequiredToo() {
        let mixed = manifest(language: .python, scripts: ["publictest_a.py", "helper_test.R"])

        let pythonOnly = profile(languages: ["python"])
        let result = RunnerLanguageGate.evaluate(runnerProfile: pythonOnly, manifest: mixed)
        #expect(!result.isCompatible)
        #expect(result.reasons.count == 1)
        #expect(result.reasons.first?.contains("provide r ") == true)
        // The reason distinguishes WHY it is needed, so an operator reading the
        // compatibility log is not sent looking for an R assignment.
        #expect(result.reasons.first?.contains("test script") == true)

        #expect(
            RunnerLanguageGate.evaluate(
                runnerProfile: profile(languages: ["python", "r"]), manifest: mixed
            ).isCompatible)
    }

    /// The declared language is still required even when no script in the suite
    /// names it — which is C++'s ordinary shape, since its generated cases are
    /// `.sh` wrappers.
    @Test func theDeclaredLanguageIsRequiredEvenWhenNoScriptNamesIt() {
        let cpp = manifest(language: .cpp, scripts: ["publictest_a.sh"])
        #expect(
            !RunnerLanguageGate.evaluate(
                runnerProfile: profile(languages: ["python"]), manifest: cpp
            ).isCompatible)
        #expect(
            RunnerLanguageGate.evaluate(
                runnerProfile: profile(languages: ["cpp"]), manifest: cpp
            ).isCompatible)
    }

    /// Extensions that name no assignment language contribute nothing, so the
    /// original mode stays claimable by anyone. `.sh` is deliberately
    /// signal-free, and the runner can dispatch interpreters Chickadee cannot
    /// author in — a suite of those must not start requiring a capability token
    /// that no runner advertises, which would queue the job forever.
    @Test(arguments: [
        ["publictest_a.sh"], ["a.sh", "b.bash"], ["helper.rb"], ["tool.js", "x.pl"],
    ])
    func aSuiteNamingNoAssignmentLanguageStaysClaimableByAnyone(_ scripts: [String]) {
        let result = RunnerLanguageGate.evaluate(
            runnerProfile: profile(languages: []),
            manifest: manifest(language: nil, scripts: scripts))
        #expect(result.isCompatible)
        #expect(result.reasons.isEmpty)
    }

    /// Two missing languages are both named, in `allCases` order rather than a
    /// Set's arbitrary one, so the compatibility log is stable.
    @Test func everyMissingLanguageIsNamedInAStableOrder() {
        let result = RunnerLanguageGate.evaluate(
            runnerProfile: profile(languages: ["python"]),
            manifest: manifest(
                language: .python, scripts: ["a.py", "b.lua", "c.R"]))
        #expect(!result.isCompatible)
        #expect(result.reasons.count == 2)
        #expect(result.reasons[0].contains("provide r "))
        #expect(result.reasons[1].contains("provide lua "))
    }

    // MARK: - Normalization

    @Test func languageTokensMatchCaseAndWhitespaceInsensitively() {
        #expect(
            RunnerLanguageGate.evaluate(
                runnerProfile: profile(languages: ["  OCTAVE "]),
                manifest: manifest(language: .octave)
            ).isCompatible)
    }

    // MARK: - allCases-driven

    /// Every language is gated, Python included. Python could not be gated
    /// before: it was the resolution default, so "this is a Python assignment"
    /// and "nothing named a language" were the same value and a gate on it would
    /// have fired on every un-identified assignment.
    @Test(arguments: AssignmentLanguage.allCases)
    func everyLanguageIsGatedBothWays(_ language: AssignmentLanguage) {
        let withIt = profile(languages: [language.capabilityName])
        #expect(
            RunnerLanguageGate.evaluate(
                runnerProfile: withIt, manifest: manifest(language: language)
            ).isCompatible,
            "a runner advertising \(language.capabilityName) must be admitted for \(language)")

        let withoutIt = profile(
            languages: AssignmentLanguage.allCases
                .filter { $0 != language }
                .map(\.capabilityName))
        #expect(
            !RunnerLanguageGate.evaluate(
                runnerProfile: withoutIt, manifest: manifest(language: language)
            ).isCompatible,
            "a runner advertising every language BUT \(language.capabilityName) must be refused")
    }
}
