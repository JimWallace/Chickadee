import Core
import Foundation

/// Server-side gate that keeps a job away from a runner that cannot grade the
/// assignment's language.
///
/// The third sibling at the claim seam, beside `CompatibilityMatcher` (an
/// explicit `AssignmentRequirementSpec` an instructor opted into) and
/// `RunnerVersionGate` (the manifest's `minimumRunnerVersion`). Unlike both, this
/// one is **implicit**: it needs no authoring step, because the assignment's
/// language is already knowable from its manifest and the runner already
/// advertises the languages it has.
///
/// Why it exists as its own gate rather than as advice to set one of the other
/// two:
///
/// - `requiredLanguages` works, but only if an instructor remembers to set it,
///   and the failure of forgetting is silent and intermittent.
/// - `minimumRunnerVersion` is a *proxy* for capability: it excludes a runner
///   whose build predates the language, but admits a current runner whose HOST
///   lacks the interpreter, which then fails at grade time. This gate catches
///   both, because it asks the runner what it actually has.
///
/// The failure it prevents: runners upgrade independently of the auto-deployed
/// server, so several `chickadee-runner` builds poll at once and claim order
/// decides which one grades a job. An assignment in a language only some of them
/// can run is graded correctly or not depending on *who answered* — it validates
/// green on a capable runner and then fails for the next student whose job an
/// older one claims, with a message (exit 127, "interpreter not found") that
/// reads as a broken test script.
///
/// Only bites the native worker path, like `RunnerVersionGate`: browser grading
/// runs the server's own vended WASM bundle and has no runner profile to check.
enum RunnerLanguageGate {

    /// Whether `runnerProfile` advertises the language this assignment is in.
    ///
    /// Compatible — with no check performed — in two cases:
    ///
    /// 1. **The assignment names no language** (`language == nil`). A suite of
    ///    plain `.sh` scripts has no interpreter to require; that is the
    ///    system's original mode and stays claimable by anyone.
    /// 2. **The runner advertises no profile at all.** That means capability
    ///    discovery is switched off (`RUNNER_CAPABILITY_DISCOVERY_ENABLED=false`),
    ///    an explicit operator choice, and treating it as incompatible would
    ///    silently stop such a runner claiming anything at all. Failing open here
    ///    costs nothing against the failure this gate is for: a runner too old to
    ///    know the language still *has* discovery on, so it advertises a profile
    ///    without the language and is caught by the closed path below.
    ///
    /// Everything else is checked: a profile that is present and does not list
    /// the language is refused, whatever the reason it is missing (build too old
    /// to probe for it, or host without the interpreter installed).
    static func evaluate(
        runnerProfile: RunnerCapabilityProfile?,
        language: AssignmentLanguage?
    ) -> CompatibilityResult {
        guard let language else { return CompatibilityResult(isCompatible: true) }
        guard let runnerProfile else { return CompatibilityResult(isCompatible: true) }

        let required = normalized(language.capabilityName)
        let advertised = Set(runnerProfile.languageVersions.map { normalized($0.language) })
        guard advertised.contains(required) else {
            return CompatibilityResult(
                isCompatible: false,
                reasons: ["runner does not provide \(required) (assignment language)"]
            )
        }
        return CompatibilityResult(isCompatible: true)
    }

    /// Matches `CompatibilityMatcher`'s own normalization so the two gates agree
    /// about what counts as the same language token.
    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
