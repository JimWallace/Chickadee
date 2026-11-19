// Tests/APITests/Grading/CompatibilityMatcherReasonTests.swift
//
// `CompatibilityMatcher.evaluate` decides whether a runner may claim a job for
// an assignment with requirements. The claim-walk suites reach it through the
// database. These tests call it directly for the branches that no claim test
// reached: a runner with no profile, a platform mismatch, and a version that
// the comparator cannot parse. Each refusal has an accepted case next to it.

import Core
import Testing

@testable import APIServer

@Suite struct CompatibilityMatcherReasonTests {

    private let matcher = CompatibilityMatcher()

    private func profile(
        platform: String = "linux",
        architecture: String = "x86_64",
        python: String = "3.12.1"
    ) -> RunnerCapabilityProfile {
        RunnerCapabilityProfile(
            platform: platform,
            architecture: architecture,
            languageVersions: [LanguageVersion(language: "Python", version: python)])
    }

    // MARK: - No profile

    @Test func aRunnerWithNoProfileIsRefusedWhenTheAssignmentHasRequirements() {
        let result = matcher.evaluate(
            runnerProfile: nil, requirements: AssignmentRequirementSpec(requiredPlatform: "linux"))
        #expect(result.isCompatible == false)
        #expect(result.reasons == ["runner profile unavailable"])
    }

    @Test func aRunnerWithNoProfileIsAcceptedWhenTheRequirementsAreBlank() {
        // Whitespace-only fields are not requirements, so no profile is needed.
        let blank = AssignmentRequirementSpec(requiredPlatform: "  ", requiredArchitecture: "\n")
        #expect(matcher.evaluate(runnerProfile: nil, requirements: blank).isCompatible)
        #expect(matcher.evaluate(runnerProfile: nil, requirements: nil).isCompatible)
    }

    // MARK: - Platform

    @Test func aPlatformMismatchIsReported() {
        let result = matcher.evaluate(
            runnerProfile: profile(platform: "darwin"),
            requirements: AssignmentRequirementSpec(requiredPlatform: "Linux"))
        #expect(result.isCompatible == false)
        #expect(result.reasons == ["platform darwin != required linux"])
    }

    @Test func thePlatformComparisonIgnoresCaseAndSpace() {
        let result = matcher.evaluate(
            runnerProfile: profile(platform: "Linux"),
            requirements: AssignmentRequirementSpec(requiredPlatform: " linux "))
        #expect(result.isCompatible)
        #expect(result.reasons.isEmpty)
    }

    // MARK: - Versions the comparator cannot parse

    @Test func anExactVersionThatDoesNotParseIsReportedAndNotTreatedAsAMatch() {
        let result = matcher.evaluate(
            runnerProfile: profile(python: "unknown"),
            requirements: AssignmentRequirementSpec(
                requiredLanguages: [AssignmentLanguageRequirement(language: "python", exactVersion: "3.12.1")]))
        #expect(result.isCompatible == false)
        #expect(result.reasons == ["unable to compare python version unknown to required 3.12.1"])
    }

    @Test func aMinimumVersionThatDoesNotParseIsReportedAndNotTreatedAsMet() {
        let result = matcher.evaluate(
            runnerProfile: profile(python: "3.12.1"),
            requirements: AssignmentRequirementSpec(
                requiredLanguages: [AssignmentLanguageRequirement(language: "python", minimumVersion: "3..1")]))
        #expect(result.isCompatible == false)
        #expect(result.reasons == ["unable to compare python version 3.12.1 to required 3..1"])
    }

    @Test func parsableVersionsAreCompared() {
        let exact = matcher.evaluate(
            runnerProfile: profile(python: "3.12.1"),
            requirements: AssignmentRequirementSpec(
                requiredLanguages: [AssignmentLanguageRequirement(language: "python", exactVersion: "3.12.1")]))
        #expect(exact.isCompatible)

        let minimum = matcher.evaluate(
            runnerProfile: profile(python: "3.12.1"),
            requirements: AssignmentRequirementSpec(
                requiredLanguages: [AssignmentLanguageRequirement(language: "python", minimumVersion: "3.11")]))
        #expect(minimum.isCompatible)
    }

    @Test func everyFailedRequirementIsReportedNotOnlyTheFirst() {
        let result = matcher.evaluate(
            runnerProfile: profile(platform: "darwin", architecture: "arm64", python: "bad"),
            requirements: AssignmentRequirementSpec(
                requiredPlatform: "linux",
                requiredArchitecture: "x86_64",
                requiredLanguages: [AssignmentLanguageRequirement(language: "python", minimumVersion: "3.11")]))
        #expect(
            result.reasons == [
                "platform darwin != required linux",
                "architecture arm64 != required x86_64",
                "unable to compare python version bad to required 3.11",
            ])
    }
}
