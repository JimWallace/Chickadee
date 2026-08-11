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

    /// Whether `runnerProfile` advertises every language this assignment needs.
    ///
    /// EVERY language, not just the declared one. The declaration says what
    /// Chickadee generates; the suite says what the runner will be asked to
    /// execute, and a suite may legitimately mix — the runner classifies each
    /// script independently and stages every language's `test_runtime.*`, so a
    /// hand-written `.R` helper inside a Python assignment runs under `Rscript`
    /// and always has. Checking only the declaration let exactly that job be
    /// claimed by an R-less runner, where it died at `exit 127 /
    /// Rscript: not found` in front of a student — this gate's own failure mode,
    /// in a shape it could not see. `languagesRequiredToGrade` answers both
    /// halves at once.
    ///
    /// Compatible — with no check performed — in two cases:
    ///
    /// 1. **Nothing requires an interpreter** (the required set is empty): no
    ///    declared language and a suite whose extensions name none, i.e. plain
    ///    `.sh`. That is the system's original mode and stays claimable by
    ///    anyone. Extensions the runner can dispatch but Chickadee cannot author
    ///    in (`.rb`, `.js`, `.pl`) also contribute nothing, so a suite of those
    ///    keeps failing open exactly as it did before.
    /// 2. **The runner advertises no profile at all.** That means capability
    ///    discovery is switched off (`RUNNER_CAPABILITY_DISCOVERY_ENABLED=false`),
    ///    an explicit operator choice, and treating it as incompatible would
    ///    silently stop such a runner claiming anything at all. Failing open here
    ///    costs nothing against the failure this gate is for: a runner too old to
    ///    know the language still *has* discovery on, so it advertises a profile
    ///    without the language and is caught by the closed path below.
    ///
    /// Everything else is checked: a profile that is present and does not list a
    /// required language is refused, whatever the reason it is missing (build too
    /// old to probe for it, or host without the interpreter installed).
    static func evaluate(
        runnerProfile: RunnerCapabilityProfile?,
        manifest: TestProperties
    ) -> CompatibilityResult {
        let required = AssignmentLanguage.languagesRequiredToGrade(manifest: manifest)
        guard !required.isEmpty else { return CompatibilityResult(isCompatible: true) }
        guard let runnerProfile else { return CompatibilityResult(isCompatible: true) }

        let advertised = Set(runnerProfile.languageVersions.map { normalized($0.language) })
        // `allCases` order, so a runner missing two languages names them in a
        // stable order rather than a Set's arbitrary one.
        let missing = AssignmentLanguage.allCases
            .filter { required.contains($0) && !advertised.contains(normalized($0.capabilityName)) }
        guard missing.isEmpty else {
            return CompatibilityResult(
                isCompatible: false,
                reasons: missing.map {
                    let role =
                        manifest.language == $0
                        ? "assignment language" : "used by a test script in the suite"
                    return "runner does not provide \(normalized($0.capabilityName)) (\(role))"
                }
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
