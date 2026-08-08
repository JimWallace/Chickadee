// Tests/APITests/RunnerLanguageGateTests.swift
//
// Unit tests for the implicit assignment-language gate (RunnerLanguageGate):
// the two fail-open short-circuits (no language, no runner profile), the
// closed path when a profile is present without the language, token
// normalization, and the allCases-driven pin that every language is gated —
// including Python, which used to be unrepresentable here because resolution
// could not tell "this is Python" from "we could not tell".

import Core
import Testing

@testable import APIServer

@Suite struct RunnerLanguageGateTests {

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
            runnerProfile: profile(languages: []), language: nil)
        #expect(result.isCompatible)
        #expect(result.reasons.isEmpty)
    }

    /// No profile means capability discovery is switched off, which is an
    /// operator's explicit choice. Treating it as incompatible would stop such a
    /// runner claiming anything at all.
    @Test func aRunnerWithNoProfileIsNotBlocked() {
        for language in AssignmentLanguage.allCases {
            #expect(
                RunnerLanguageGate.evaluate(runnerProfile: nil, language: language).isCompatible,
                "a profile-less runner must not be blocked from \(language) work")
        }
    }

    // MARK: - The closed path

    @Test func aProfileWithoutTheLanguageIsRefused() {
        let result = RunnerLanguageGate.evaluate(
            runnerProfile: profile(languages: ["python"]), language: .octave)
        #expect(!result.isCompatible)
        #expect(result.reasons.count == 1)
        #expect(result.reasons.first?.contains("octave") == true)
    }

    @Test func aProfileWithTheLanguageIsAdmitted() {
        #expect(
            RunnerLanguageGate.evaluate(
                runnerProfile: profile(languages: ["python", "octave"]), language: .octave
            ).isCompatible)
    }

    /// The scenario the gate exists for: a runner whose BUILD predates the
    /// language advertises a profile that simply lacks it, so it leaves the job
    /// for a runner that can grade it instead of failing it with exit 127.
    @Test func anOlderRunnerLeavesANewLanguagesJobAlone() {
        let old = profile(languages: ["python", "r"])
        let current = profile(languages: ["python", "r", "lua", "octave", "cpp"])
        #expect(!RunnerLanguageGate.evaluate(runnerProfile: old, language: .octave).isCompatible)
        #expect(RunnerLanguageGate.evaluate(runnerProfile: current, language: .octave).isCompatible)
    }

    /// The case a `minimumRunnerVersion` gate cannot catch: the runner is new
    /// enough, but its HOST has no interpreter, so it never advertises one.
    @Test func aCurrentRunnerMissingTheInterpreterIsAlsoRefused() {
        #expect(
            !RunnerLanguageGate.evaluate(
                runnerProfile: profile(languages: ["python", "r", "lua"]), language: .octave
            ).isCompatible)
    }

    // MARK: - Normalization

    @Test func languageTokensMatchCaseAndWhitespaceInsensitively() {
        #expect(
            RunnerLanguageGate.evaluate(
                runnerProfile: profile(languages: ["  OCTAVE "]), language: .octave
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
            RunnerLanguageGate.evaluate(runnerProfile: withIt, language: language).isCompatible,
            "a runner advertising \(language.capabilityName) must be admitted for \(language)")

        let withoutIt = profile(
            languages: AssignmentLanguage.allCases
                .filter { $0 != language }
                .map(\.capabilityName))
        #expect(
            !RunnerLanguageGate.evaluate(runnerProfile: withoutIt, language: language).isCompatible,
            "a runner advertising every language BUT \(language.capabilityName) must be refused")
    }
}
