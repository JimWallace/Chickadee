// APIServer/Utilities/AuthoringChecks/ZeroPointsCheck.swift
//
// Reports each suite entry worth zero points (#2747). A zero-point test still
// runs and shows its result, but it adds nothing to the grade. That is
// sometimes deliberate (a diagnostic check), so the severity is `info`.

import Core

struct ZeroPointsCheck: AuthoringCheck {
    static let id = "points.zeroPoints"
    static let severity = AuthoringFinding.Severity.info

    func findings(in snapshot: AuthoringSnapshot) -> [AuthoringFinding] {
        snapshot.manifest.testSuites.filter { $0.points == 0 }.map { entry in
            finding(
                at: .suiteItem(entry.script),
                "\(entry.name ?? entry.script) is worth 0 points, so it does not count toward the grade.",
                fix: "Give it points, or leave it at 0 if it is a diagnostic test.")
        }
    }
}
