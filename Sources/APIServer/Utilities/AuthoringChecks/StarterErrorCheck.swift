// APIServer/Utilities/AuthoringChecks/StarterErrorCheck.swift
//
// Reports graded tests that end in `error`, not `fail`, on the unmodified
// starter while the solution passes them (#2747). A test reports `error` when
// the script itself breaks, typically on a name the starter does not define,
// so a student who runs the tests early sees a traceback instead of the test's
// failure message. Often deliberate, so the severity is `info`, and the tests
// are listed in one finding.

import Core

struct StarterErrorCheck: AuthoringCheck {
    static let id = "starter.errorsInsteadOfFails"
    static let severity = AuthoringFinding.Severity.info

    func findings(in snapshot: AuthoringSnapshot) -> [AuthoringFinding] {
        let erroring = snapshot.gradedEntriesOnStarter().filter { $0.starter?.status == .error }.map(\.entry)
        guard !erroring.isEmpty else { return [] }
        let names = erroring.map { $0.name ?? $0.script }.joined(separator: ", ")
        return [
            finding(
                at: .assignment,
                "\(erroring.count) graded \(erroring.count == 1 ? "test reports" : "tests report") an error, "
                    + "not a failure, on the unmodified starter: \(names). A student who runs the tests "
                    + "before finishing sees a traceback instead of the test's failure message.",
                fix: "Give the starter a stub for each name these tests call, so an unfinished answer "
                    + "fails with the test's message.")
        ]
    }
}
