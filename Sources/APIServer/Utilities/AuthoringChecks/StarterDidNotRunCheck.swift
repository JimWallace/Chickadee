// APIServer/Utilities/AuthoringChecks/StarterDidNotRunCheck.swift
//
// Reports a starter run that did not run (#2747): the starter notebook a
// student opens did not build, ran no test, or errored on every test. The
// reason is `StarterValidationRun.failure(of:)`, the one the workbench shows as
// "Starter didn't run", so the two cannot disagree. While the starter does not
// run, `starter.passesGradedTest` and `starter.errorsInsteadOfFails` find
// nothing, because its outcomes say nothing about the tests.

import Core

struct StarterDidNotRunCheck: AuthoringCheck {
    static let id = "starter.didNotRun"
    static let severity = AuthoringFinding.Severity.warning

    func findings(in snapshot: AuthoringSnapshot) -> [AuthoringFinding] {
        guard let starterRun = snapshot.starterRun, let reason = StarterValidationRun.failure(of: starterRun) else {
            return []
        }
        return [
            finding(
                at: .assignment,
                "The starter notebook, as students receive it, did not run against the suite: \(reason). "
                    + "A student who runs the tests before writing any code meets this first, and the "
                    + "starter checks cannot tell whether a test passes for no work.",
                fix: "Make the starter notebook build as handed out. If every test errors, give the "
                    + "starter a stub for each name the tests call.")
        ]
    }
}
