// APIServer/Utilities/AuthoringChecks/MissingMetricCheck.swift
//
// Reports a class activity that ranks on a leaderboard while the reference
// solution's run reports no `metric` (#2747). The leaderboard sorts on
// `metric` and nothing else (`docs/class-activities.md`), so without one no
// student gets a ranking position.

import Core

struct MissingMetricCheck: AuthoringCheck {
    static let id = "activity.noMetric"
    static let severity = AuthoringFinding.Severity.warning

    func findings(in snapshot: AuthoringSnapshot) -> [AuthoringFinding] {
        guard let activity = snapshot.manifest.activity, activity.kind.aggregation == .leaderboard,
            let solutionRun = snapshot.solutionRun, !solutionRun.outcomes.isEmpty,
            !solutionRun.outcomes.contains(where: { $0.metric != nil })
        else { return [] }
        return [
            finding(
                at: .assignment,
                "The \(activity.kind.displayName) activity ranks on a leaderboard, but no test in the "
                    + "reference solution's run reported a metric, so no student would get a ranking position.",
                fix: "Have the ranking test print a JSON last line with a numeric \"metric\".")
        ]
    }
}
