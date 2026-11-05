// APIServer/Utilities/AuthoringChecks/TimingMarginCheck.swift
//
// Reports each test on which the reference solution used more than half of its
// time limit (#2747). Runners differ in speed and a student's code is rarely
// faster than the solution, so a slim margin times out correct submissions.
// The limit is per script: the entry's own, else the assignment's.

import Core

struct TimingMarginCheck: AuthoringCheck {
    static let id = "timing.margin"
    static let severity = AuthoringFinding.Severity.warning

    /// The share of the limit the solution may use before this check reports.
    static let marginFraction = 0.5

    func findings(in snapshot: AuthoringSnapshot) -> [AuthoringFinding] {
        guard let solutionRun = snapshot.solutionRun else { return [] }
        let manifest = snapshot.manifest
        let outcomes = solutionRun.outcomesByScript(in: manifest)
        return manifest.testSuites.compactMap { entry in
            guard let outcome = outcomes[entry.script], outcome.status == .pass else { return nil }
            let limitSeconds = entry.timeLimitSeconds ?? manifest.timeLimitSeconds
            let usedSeconds = Double(outcome.executionTimeMs) / 1000
            guard usedSeconds > Double(limitSeconds) * Self.marginFraction else { return nil }
            let suggested = Int((usedSeconds / Self.marginFraction).rounded(.up))
            return finding(
                at: .suiteItem(entry.script),
                "The reference solution took \((usedSeconds * 10).rounded() / 10) s of the \(limitSeconds) s "
                    + "limit on \(entry.name ?? entry.script), so a correct but slower submission may time out.",
                fix: "Raise the time limit to at least \(suggested) s, or make the test faster.")
        }
    }
}
