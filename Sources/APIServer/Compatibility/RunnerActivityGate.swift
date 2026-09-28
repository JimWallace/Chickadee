import Core
import Foundation

/// Server-side gate that keeps a class-activity match job away from a runner
/// build that cannot stage its opponent (docs/class-activities.md).
///
/// The fourth sibling at the claim seam, beside `CompatibilityMatcher`,
/// `RunnerVersionGate` and `RunnerLanguageGate`, and shaped like the language
/// gate: implicit, with no authoring step. The manifest already says whether
/// the activity stages an opponent, and every runner build that can stage one
/// advertises `activity-match` (`RunnerProfileDetector.buildCapabilities`).
///
/// The failure it prevents is the language gate's, one field over. A match
/// job's opponent travels on `Job.opponent`, a key an older runner's decoder
/// ignores; that runner would grade the bot match with no bot in the workspace
/// and no error, and a script that finds nothing to play against reads as a
/// win. `minimumRunnerVersion` is the wrong tool for this: the capability is
/// observable, so it is checked rather than proxied by a version number.
///
/// Fails open in the same two cases as the language gate: nothing to stage (an
/// ordinary assignment, an activity whose opponent source is `none`, or a bot
/// kind whose file is not chosen yet — which grades as it did before the
/// primitive and stays claimable by every build), and a runner advertising no
/// profile at all (discovery switched off, an operator's choice — an old
/// runner still has discovery on and is caught).
enum RunnerActivityGate {

    static func evaluate(
        runnerProfile: RunnerCapabilityProfile?,
        manifest: TestProperties
    ) -> CompatibilityResult {
        guard let activity = manifest.activity, activity.stagesAnOpponent,
            let required = activity.kind.opponentSource.requiredRunnerCapability
        else {
            return CompatibilityResult(isCompatible: true)
        }
        guard let runnerProfile else { return CompatibilityResult(isCompatible: true) }
        let advertised = Set(runnerProfile.capabilities.map { normalized($0.name) })
        guard advertised.contains(normalized(required.name)) else {
            return CompatibilityResult(
                isCompatible: false,
                reasons: [
                    "runner does not provide \(required.name) "
                        + "(this \(activity.kind.displayName.lowercased()) activity stages an opponent)"
                ]
            )
        }
        return CompatibilityResult(isCompatible: true)
    }

    /// `CompatibilityMatcher`'s normalization, so the gates agree about what
    /// counts as the same token.
    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
