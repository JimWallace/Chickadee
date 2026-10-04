// Tests/WorkerTests/ProcessInspectionTests.swift
//
// The runner and the server call `chickadee_refuse_process_inspection()` at
// start, so a child process of the same user cannot read their environment
// through /proc. The call changes process-global state, so each test runs in a
// child process (`#expect(processExitsWith:)`) and the test runner itself stays
// dumpable.
//
// What this cannot show in CI: that a same-user child is refused. CI runs as
// root in a privileged container, and root may read /proc regardless. The
// kernel's rule is that a non-dumpable process refuses a reader without
// CAP_SYS_PTRACE, so the test checks the flag the rule reads.

import CProcessHardening
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct ProcessInspectionTests {

    #if os(Linux)
    @Test func refusingInspectionClearsTheDumpableFlag() async {
        await #expect(processExitsWith: .success) {
            guard chickadee_process_inspection_allowed() == 1 else { exit(2) }
            guard chickadee_refuse_process_inspection() == 0 else { exit(3) }
            guard chickadee_process_inspection_allowed() == 0 else { exit(4) }
            exit(0)
        }
    }
    #else
    @Test func refusingInspectionIsANoOpOffLinux() {
        #expect(chickadee_refuse_process_inspection() == 0)
        #expect(chickadee_process_inspection_allowed() == -1)
    }
    #endif
}
