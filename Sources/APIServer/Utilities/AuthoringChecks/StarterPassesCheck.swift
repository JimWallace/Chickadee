// APIServer/Utilities/AuthoringChecks/StarterPassesCheck.swift
//
// Reports each graded test that the unmodified starter notebook passes (#2747).
// Such a test awards its points for no work. The rule matches the workbench's
// "passes on the starter" issue (`InstructorSuiteOutlineBuilder`): the starter
// passes, the solution passes, and the test is worth points. A starter run that
// did not run (`StarterValidationRun.failure`) says nothing about the tests.

import Core

struct StarterPassesCheck: AuthoringCheck {
    static let id = "starter.passesGradedTest"
    static let severity = AuthoringFinding.Severity.warning

    func findings(in snapshot: AuthoringSnapshot) -> [AuthoringFinding] {
        snapshot.gradedEntriesOnStarter().compactMap { entry, starter in
            guard starter?.status == .pass else { return nil }
            return finding(
                at: .suiteItem(entry.script),
                "\(entry.name ?? entry.script) passes on the unmodified starter notebook, "
                    + "so it awards \(entry.points) points for no work.",
                fix: "Make the test check what the student must write, or give it 0 points.")
        }
    }
}
