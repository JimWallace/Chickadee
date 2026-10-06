// APIServer/Services/ClaimCompatibility.swift
//
// The one decision of whether a runner may grade a job. The claim walk
// (`evaluateAndClaimCandidate`) and the unclaimable-jobs health rule both use
// it, so a job the alert calls unclaimable is exactly a job that no runner
// would claim.

import Core
import Foundation

/// Whether a runner with `runnerVersion` and `runnerProfile` may grade a job
/// for `manifest`: the assignment's capability `requirements`, the runner
/// version (the deployment floor and the manifest's `minimumRunnerVersion`),
/// the language the suite needs, and what a class-activity match needs.
func claimCompatibility(
    runnerVersion: String,
    runnerProfile: RunnerCapabilityProfile?,
    manifest: TestProperties,
    requirements: AssignmentRequirementSpec?,
    matcher: CompatibilityMatcher = CompatibilityMatcher()
) -> CompatibilityResult {
    let capabilityResult = matcher.evaluate(runnerProfile: runnerProfile, requirements: requirements)
    let versionResult = RunnerVersionGate.combine(
        RunnerVersionGate.evaluateDeploymentFloor(runnerVersion: runnerVersion),
        RunnerVersionGate.evaluate(runnerVersion: runnerVersion, minimumRunnerVersion: manifest.minimumRunnerVersion)
    )
    let languageResult = RunnerLanguageGate.evaluate(runnerProfile: runnerProfile, manifest: manifest)
    let activityResult = RunnerActivityGate.evaluate(runnerProfile: runnerProfile, manifest: manifest)
    return RunnerVersionGate.combine(
        RunnerVersionGate.combine(RunnerVersionGate.combine(capabilityResult, versionResult), languageResult),
        activityResult
    )
}
