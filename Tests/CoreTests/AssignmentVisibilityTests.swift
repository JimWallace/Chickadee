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
}
