// Tests/CoreTests/SuiteEntryOriginTests.swift
//
// `TestSuiteEntry.origin` states the three real states of the two stored
// generator fields.  These tests pin each state, the tie-break for a manifest
// that sets both, and that `isGenerated` agrees with it.

import Foundation
import Testing

@testable import Core

@Suite struct SuiteEntryOriginTests {

    @Test func entryWithNeitherFieldIsHandWritten() {
        let entry = TestSuiteEntry(tier: .pub, script: "test_a.sh")
        #expect(entry.origin == .handWritten)
        #expect(!entry.isGenerated)
    }

    @Test func entryWithFamilyIsFamily() {
        let entry = TestSuiteEntry(tier: .pub, script: "pubtest_f_a.py", generatedBy: "f")
        #expect(entry.origin == .family(id: "f"))
        #expect(entry.isGenerated)
    }

    @Test func entryWithCheckIsCheck() {
        let entry = TestSuiteEntry(tier: .pub, script: "pubtest_c.py", generatedByCheck: "c")
        #expect(entry.origin == .check(id: "c"))
        #expect(entry.isGenerated)
    }

    /// Validation refuses this pair, but a hand-edited zip can carry it.  The
    /// family wins, as it did at every call site that tested the fields in turn.
    @Test func entryWithBothFieldsIsFamily() {
        let entry = TestSuiteEntry(
            tier: .pub, script: "pubtest_x.py", generatedBy: "f", generatedByCheck: "c")
        #expect(entry.origin == .family(id: "f"))
    }

    /// The origin reads the decoded fields, so a stored entry gets the same
    /// answer as one built in memory.
    @Test func decodedEntryHasOrigin() throws {
        let json = #"{"tier":"public","script":"pubtest_c.py","generatedByCheck":"c"}"#
        let entry = try JSONDecoder().decode(TestSuiteEntry.self, from: Data(json.utf8))
        #expect(entry.origin == .check(id: "c"))
    }
}
