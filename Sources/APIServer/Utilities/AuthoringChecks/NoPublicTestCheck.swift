// APIServer/Utilities/AuthoringChecks/NoPublicTestCheck.swift
//
// Reports a suite with tests but none in the `public` tier (#2747). Secret
// output is never shown, and release output can stay hidden until the deadline
// (`releaseVisibilityDeadline`, which also reads the course's release hold), so
// without a public test a student may get no test output while they work. The
// snapshot does not hold the course policy, so the message says "may".

import Core

struct NoPublicTestCheck: AuthoringCheck {
    static let id = "tiers.noPublicTest"
    static let severity = AuthoringFinding.Severity.warning

    func findings(in snapshot: AuthoringSnapshot) -> [AuthoringFinding] {
        let suite = snapshot.manifest.testSuites
        guard !suite.isEmpty, !suite.contains(where: { $0.tier == .pub }) else { return [] }
        return [
            finding(
                at: .assignment,
                "No test is in the public tier. Secret output is never shown and release output can stay "
                    + "hidden until the deadline, so students may see no test output while they work.",
                fix: "Move at least one test to the public tier, unless hiding all output is intended.")
        ]
    }
}
