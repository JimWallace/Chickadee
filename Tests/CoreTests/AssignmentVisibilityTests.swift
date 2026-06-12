import Testing

@testable import Core

@Suite struct AssignmentVisibilityTests {
    @Test func acceptsStudentSubmissionsOnlyWhenOpen() {
        #expect(AssignmentVisibility.open.acceptsStudentSubmissions)
        #expect(!AssignmentVisibility.preview.acceptsStudentSubmissions)
        #expect(!AssignmentVisibility.closed.acceptsStudentSubmissions)
    }

    @Test func legacyIsOpenMapsToOpenOrClosed() {
        #expect(AssignmentVisibility(legacyIsOpen: true) == .open)
        // The legacy boolean cannot express preview; false is always closed.
        #expect(AssignmentVisibility(legacyIsOpen: false) == .closed)
    }

    @Test func rawValuesAreStable() {
        // These strings are persisted (DB column + course bundles); guard them.
        #expect(AssignmentVisibility.closed.rawValue == "closed")
        #expect(AssignmentVisibility.preview.rawValue == "preview")
        #expect(AssignmentVisibility.open.rawValue == "open")
    }

    @Test func submissionGateTreatsOpenAndClosedTheSameForBothViewers() {
        for isStaff in [true, false] {
            let openGate = AssignmentVisibility.open.submissionGate(isStaff: isStaff)
            #expect(openGate.treatAsOpen)
            #expect(openGate.honorsStartDate)

            let closedGate = AssignmentVisibility.closed.submissionGate(isStaff: isStaff)
            #expect(!closedGate.treatAsOpen)
            #expect(closedGate.honorsStartDate)
        }
    }

    @Test func submissionGatePreviewIsStaffOnlyAndStaffBypassTheStartDate() {
        // Staff: preview behaves as open, AND the future-open-date gate is
        // bypassed so they can test before the scheduled open date.
        let staffGate = AssignmentVisibility.preview.submissionGate(isStaff: true)
        #expect(staffGate.treatAsOpen)
        #expect(!staffGate.honorsStartDate)

        // Students: preview is closed, and the start-date gate still applies
        // (redundant with treatAsOpen == false, but never accidentally open).
        let studentGate = AssignmentVisibility.preview.submissionGate(isStaff: false)
        #expect(!studentGate.treatAsOpen)
        #expect(studentGate.honorsStartDate)
    }
}
