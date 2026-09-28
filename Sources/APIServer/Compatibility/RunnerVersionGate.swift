import Core
import Foundation

/// Server-side gate for the manifest's optional `minimumRunnerVersion`
/// (`TestProperties.minimumRunnerVersion`): a submission is only handed to a
/// native runner whose advertised version (`WorkerActivityPayload.runnerVersion`,
/// i.e. `ChickadeeVersion.current`) is `>=` the manifest's minimum.
///
/// This is a *sibling* to `CompatibilityMatcher`, deliberately not folded into
/// it: the capability matcher compares a `RunnerCapabilityProfile` against an
/// `AssignmentRequirementSpec`, whereas this gate compares the runner's build
/// version against a value carried on the manifest.  Keeping them separate
/// avoids coupling the matcher to a manifest concern; `combine(_:_:)` merges the
/// two verdicts into one `CompatibilityResult` at the claim seam so the existing
/// guard / diagnostics / blocked-candidate path is reused unchanged.
///
/// Only bites the native worker path.  Browser (`gradingMode: .browser`) grading
/// runs the server's own vended WASM bundle — there is no runner version to
/// gate — so this never applies there.
enum RunnerVersionGate {
    /// The oldest runner build this server hands any job to, whatever the
    /// manifest says (#1249). It is the retirement path for wire shims: raise
    /// it in a PR at or above the version that introduced a wire change, and
    /// the server may then rely on every claiming runner speaking that shape.
    /// The runner-version-skew alert shows a runner that has not upgraded.
    ///
    /// A constant rather than an environment variable, on purpose: the floor
    /// is a property of the server code (which shims it still carries), not
    /// of a deployment.
    static let deploymentMinimumRunnerVersion = "0.5.0"

    /// Whether the deployment floor admits a runner advertising `runnerVersion`.
    ///
    /// Unlike a manifest minimum, the floor fails OPEN on a version it cannot
    /// parse. It applies to every job, and mock and third-party runners
    /// advertise non-semver strings (`runner/1.0`); refusing those would turn
    /// a safety net into an outage. It refuses only a real semver below the
    /// floor, which is the one case it can prove is too old.
    static func evaluateDeploymentFloor(
        runnerVersion: String,
        floor: String = deploymentMinimumRunnerVersion
    ) -> CompatibilityResult {
        guard VersionComparator().compare(runnerVersion, floor) == .orderedAscending else {
            return CompatibilityResult(isCompatible: true)
        }
        return CompatibilityResult(
            isCompatible: false,
            reasons: ["runner version \(runnerVersion) < deployment minimum \(floor)"]
        )
    }

    /// Whether the manifest gate admits a runner advertising `runnerVersion`.
    ///
    /// A `nil`/blank minimum short-circuits to *compatible* **without inspecting
    /// `runnerVersion` at all** — so an un-gated assignment is unaffected even
    /// when the runner advertises a non-semver string (mock/third-party runners
    /// do), and the existing byte-for-byte behaviour is preserved.  When a real
    /// minimum is set and either side is unparseable, the gate fails *closed*:
    /// we cannot prove the runner meets the floor, so we refuse rather than risk
    /// grading on an unidentifiable runner.
    static func evaluate(runnerVersion: String, minimumRunnerVersion: String?) -> CompatibilityResult {
        let minimum = (minimumRunnerVersion ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !minimum.isEmpty else {
            return CompatibilityResult(isCompatible: true)
        }

        guard let comparison = VersionComparator().compare(runnerVersion, minimum) else {
            return CompatibilityResult(
                isCompatible: false,
                reasons: ["unparseable runner version '\(runnerVersion)' (required minimum \(minimum))"]
            )
        }

        if comparison == .orderedAscending {
            return CompatibilityResult(
                isCompatible: false,
                reasons: ["runner version \(runnerVersion) < required minimum \(minimum)"]
            )
        }

        return CompatibilityResult(isCompatible: true)
    }

    /// Whether `version` is a semver the gate can compare — used to reject a
    /// malformed `minimumRunnerVersion` at manifest-ingest time.
    static func isParseable(_ version: String) -> Bool {
        VersionComparator().canParse(version)
    }

    /// Fold two verdicts: compatible only when both are; reasons concatenated.
    static func combine(_ lhs: CompatibilityResult, _ rhs: CompatibilityResult) -> CompatibilityResult {
        CompatibilityResult(
            isCompatible: lhs.isCompatible && rhs.isCompatible,
            reasons: lhs.reasons + rhs.reasons
        )
    }
}
