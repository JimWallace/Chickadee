// APIServer/Utilities/AuthoringChecks/NoGradedTestCheck.swift
//
// Reports a suite whose tests are all worth zero points (#2747). The grade is
// earned points over total points, and with a total of zero there is no grade:
// the aggregates leave it empty (`StudentSubmissionAggregates`). Each
// zero-point test is also reported, as `info`, by `points.zeroPoints`; this is
// the assignment-level consequence.

import Core

struct NoGradedTestCheck: AuthoringCheck {
    static let id = "points.noGradedTest"
    static let severity = AuthoringFinding.Severity.warning

    func findings(in snapshot: AuthoringSnapshot) -> [AuthoringFinding] {
        let suite = snapshot.manifest.testSuites
        guard !suite.isEmpty, suite.allSatisfy({ $0.points == 0 }) else { return [] }
        return [
            finding(
                at: .assignment,
                "Every test is worth 0 points, so a submission gets no grade.",
                fix: "Give the tests that grade the assignment their points.")
        ]
    }
}
